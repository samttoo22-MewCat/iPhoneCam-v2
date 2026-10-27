// PhoneLensReceiver — macOS side of the PhoneLens USB camera tunnel.
//
// Phone side: PLNS v1 server listening on 127.0.0.1:8765 (PlnsServer.swift).
// This tool speaks the native usbmuxd protocol (/var/run/usbmuxd) — no
// iproxy/brew dependency — opens a Connect to the phone's port, parses the
// PLNS stream (CONFIG/ACCESS_UNIT/KEEP_ALIVE) and decodes H.264 Annex-B into
// an AVSampleBufferDisplayLayer so the phone becomes a local video window.
//
// Build:
//   swiftc -O PhoneLensReceiver.swift -o PhoneLensReceiver \
//     -framework AppKit -framework CoreMedia -framework CoreVideo -framework Foundation
// Run:
//   ./PhoneLensReceiver            # auto-connects to the first USB iPhone
import AVFoundation
import AppKit
import CoreMedia
import CoreVideo
import Foundation
import SystemExtensions

// MARK: - usbmuxd (native, zero dependencies)

private let usbmuxdPath = "/var/run/usbmuxd"
private let muxHeaderSize = 16

private enum MuxMessageType {
    static let result: UInt32 = 1
    static let plistData: UInt32 = 8
}

private struct MuxMessage {
    static let version: UInt32 = 1
    var type: UInt32
    var tag: UInt32
    var payload: Data

    static func plist(_ dict: [String: Any], type: UInt32, tag: UInt32) -> MuxMessage? {
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: dict, format: .binary, options: 0) else { return nil }
        return MuxMessage(type: type, tag: tag, payload: data)
    }
}

private enum MuxError: Error, CustomStringConvertible {
    case connectFailed(String)
    case shortRead
    case badResult(Int)
    case noDevice

    var description: String {
        switch self {
        case .connectFailed(let why): return "usbmuxd 連線失敗：\(why)"
        case .shortRead: return "usbmuxd 連線中斷"
        case .badResult(let n): return "usbmuxd 拒絕（result \(n)）"
        case .noDevice: return "找不到透過 USB 連接的 iPhone"
        }
    }
}

private final class MuxSocket {
    private(set) var fd: Int32 = -1

    func open() throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MuxError.connectFailed("socket() errno \(errno)") }
        // sockaddr_un: sun_len(u8) sun_family(u8) sun_path[104]，用位元組陣列組裝，
        // 避開同一 struct 內子區域與整體的疊區存取（-O 下曾觸發 exclusivity 崩潰）。
        let saSize = MemoryLayout<sockaddr_un>.size
        var sa = [UInt8](repeating: 0, count: saSize)
        sa[0] = UInt8(saSize)
        sa[1] = UInt8(AF_UNIX)
        let pathBytes = Array(usbmuxdPath.utf8CString)
        for (i, b) in pathBytes.enumerated() where i < saSize - 3 { sa[2 + i] = UInt8(b) }
        let connected = sa.withUnsafeBytes { raw -> Bool in
            let ptr = raw.bindMemory(to: sockaddr.self).baseAddress!
            return Darwin.connect(fd, ptr, UInt32(saSize)) == 0
        }
        guard connected else {
            Darwin.close(fd); fd = -1
            throw MuxError.connectFailed("connect() errno \(errno)")
        }
    }

    func send(_ message: MuxMessage) throws {
        // 純算術組 little-endian header。Xcode 27 -O 下
        // withUnsafeBytes(of: [UInt32]) 曾產生錯誤長度與垃圾位元組。
        func le32(_ v: UInt32) -> [UInt8] {
            [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(muxHeaderSize + message.payload.count)
        bytes += le32(UInt32(muxHeaderSize + message.payload.count))
        bytes += le32(MuxMessage.version)
        bytes += le32(message.type)
        bytes += le32(message.tag)
        bytes += [UInt8](message.payload)
        try sendRaw(Data(bytes))
    }

    private func sendRaw(_ data: Data) throws {
        var buffer = [UInt8](data)
        var sent = 0
        while sent < buffer.count {
            let n = buffer.withUnsafeBytes { raw -> Int in
                Darwin.send(fd, raw.baseAddress!.advanced(by: sent),
                            buffer.count - sent, 0)
            }
            guard n > 0 else { throw MuxError.shortRead }
            sent += n
        }
    }

    /// Reads one usbmuxd message; plist payload parsed for plist/result types.
    func receive() throws -> (type: UInt32, plist: [String: Any]?) {
        let header = try readFully(muxHeaderSize)
        let length = Int(readLE32(header, 0))
        guard length >= muxHeaderSize, length <= 1 << 22 else { throw MuxError.shortRead }
        let body = try readFully(length - muxHeaderSize)
        let type = readLE32(header, 8)
        var plistDict: [String: Any]?
        if type == MuxMessageType.plistData || type == MuxMessageType.result {
            plistDict = (try? PropertyListSerialization.propertyList(
                from: Data(body), options: [], format: nil)) as? [String: Any]
        }
        return (type, plistDict)
    }

    private func readFully(_ count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                Darwin.recv(fd, raw.baseAddress!.advanced(by: got), count - got, 0)
            }
            guard n > 0 else { throw MuxError.shortRead }
            got += n
        }
        return buffer
    }

    private func readLE32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8) |
        (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }
}

// MARK: - PLNS v1 parser

enum PLNS {
    static let magic: UInt32 = 0x504C_4E53
    static let headerBytes = 24
    static let kindConfig: UInt8 = 1
    static let kindAccessUnit: UInt8 = 2
    static let kindKeepAlive: UInt8 = 3
    static let flagKeyFrame: UInt8 = 0x01

    struct Packet {
        var kind: UInt8
        var keyFrame: Bool
        var sequence: Int32
        var ptsUs: Int64
        var payload: Data
    }
}

final class PLNSParser {
    private var buffer = Data()

    private func logAnomaly(_ text: String) {
        let line = "\(Date()) ANOMALY \(text)\n"
        if let data = line.data(using: .utf8) {
            if !FileManager.default.fileExists(atPath: "/tmp/phonelens-recv/parser.log") {
                FileManager.default.createFile(atPath: "/tmp/phonelens-recv/parser.log", contents: nil)
            }
            if let handle = FileHandle(forWritingAtPath: "/tmp/phonelens-recv/parser.log") {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        }
    }

    func feed(_ data: Data) -> [PLNS.Packet] {
        buffer.append(data)
        var packets: [PLNS.Packet] = []
        while true {
            guard buffer.count >= PLNS.headerBytes else { break }
            let bytes = [UInt8](buffer.prefix(PLNS.headerBytes))
            guard readU32(bytes, 0) == PLNS.magic else {
                // Resync: scan forward for the next plausible magic.
                var offset = 1
                let all = [UInt8](buffer)
                while offset + 4 <= all.count {
                    if readU32(all, offset) == PLNS.magic { break }
                    offset += 1
                }
                buffer.removeFirst(min(offset, buffer.count))
                continue
            }
            let version = (UInt16(bytes[4]) << 8) | UInt16(bytes[5])
            guard version == 1 else { buffer.removeAll(); continue }
            let kind = bytes[6]
            let flags = bytes[7]
            let seq = Int32(bitPattern: readU32(bytes, 8))
            let pts = Int64(bitPattern: readU64(bytes, 12))
            let payloadLen = Int(readU32(bytes, 20))
            guard payloadLen <= 8 * 1024 * 1024 else { buffer.removeAll(); continue }
            guard buffer.count >= PLNS.headerBytes + payloadLen else { break }
            // NOTE: under -O on this toolchain, Data.subdata(in:) with a
            // computed range has trapped even when the guard above passes
            // (same family as the withUnsafeBytes(of:) miscompile). Use
            // total functions so a bad length can never crash the receiver.
            let slice = buffer.dropFirst(PLNS.headerBytes).prefix(payloadLen)
            if slice.count != payloadLen {
                logAnomaly("short prefix count=\(buffer.count) want=\(PLNS.headerBytes + payloadLen)")
                buffer.removeFirst(buffer.count)
                continue
            }
            let payload = Data(slice)
            buffer.removeFirst(PLNS.headerBytes + payloadLen)
            if kind != PLNS.kindKeepAlive {
                packets.append(PLNS.Packet(kind: kind, keyFrame: flags & PLNS.flagKeyFrame != 0,
                                           sequence: seq, ptsUs: pts, payload: payload))
            }
        }
        return packets
    }

    private func readU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16) |
        (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }

    private func readU64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 { value = (value << 8) | UInt64(bytes[offset + i]) }
        return value
    }
}

// MARK: - H.264 decode + display

protocol DecodedFrameSink: AnyObject {
    func decodedFrame(_ pixelBuffer: CVPixelBuffer)
}

/// H.264 Annex-B -> VideoToolbox decode -> CVPixelBuffer.
/// Same PLNS/AVCC path as the standalone receiver, but frames go to the
/// shared-memory slot (for the camera extension) instead of a display layer.
final class H264Sink: NSObject {
    private weak var sink: DecodedFrameSink?
    private let queue = DispatchQueue(label: "tw.phonecamera.receiver.decode")
    private var format: CMVideoFormatDescription?
    private let annexBParser = AnnexBSplitter()
    private var session: VTDecompressionSession?

    func setSink(_ sink: DecodedFrameSink?) {
        queue.async { [self] in
            self.sink = sink
            refBox.sink = sink
        }
    }

    func handle(_ packet: PLNS.Packet) {
        queue.async { [self] in
            switch packet.kind {
            case PLNS.kindConfig:
                makeFormat(packet.payload)
            case PLNS.kindAccessUnit:
                enqueue(packet)
            default: break
            }
        }
    }

    private let decodeCallback: VTDecompressionOutputCallback = {
        (refCon, _, status, _, imageBuffer, _, _) in
        guard status == noErr, let imageBuffer,
              let refCon else { return }
        let sinkHolder = Unmanaged<RefBox>.fromOpaque(refCon).takeUnretainedValue()
        sinkHolder.sink?.decodedFrame(imageBuffer)
    }

    private final class RefBox {
        weak var sink: DecodedFrameSink?
    }
    private let refBox = RefBox()

    private func makeFormat(_ annexB: Data) {
        let units = annexBParser.split(annexB) // start codes removed
        var sps: Data?
        var pps: Data?
        for unit in units where unit.count > 1 {
            let type = [UInt8](unit)[0] & 0x1F
            if type == 7 && sps == nil { sps = unit }
            if type == 8 && pps == nil { pps = unit }
        }
        guard let sps, let pps, !sps.isEmpty, !pps.isEmpty else { return }
        var desc: CMVideoFormatDescription?
        let ok: Bool = sps.withUnsafeBytes { spsRaw -> Bool in
            pps.withUnsafeBytes { ppsRaw -> Bool in
                guard let sBase = spsRaw.baseAddress, let pBase = ppsRaw.baseAddress else {
                    return false
                }
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2,
                    parameterSetPointers: [sBase.assumingMemoryBound(to: UInt8.self),
                                           pBase.assumingMemoryBound(to: UInt8.self)],
                    parameterSetSizes: [sps.count, pps.count],
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &desc)
                return status == noErr
            }
        }
        if ok, let desc {
            format = desc
            session.map(VTDecompressionSessionInvalidate)
            session = nil
            // VideoToolbox decode: output IOSurface-backed buffers directly.
            let attrs: NSDictionary = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
            ]
            var newSession: VTDecompressionSession?
            let decoderSpec: NSDictionary = [
                kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
            ]
            let ref = Unmanaged.passUnretained(refBox).toOpaque()
            var record = VTDecompressionOutputCallbackRecord(
                decompressionOutputCallback: decodeCallback,
                decompressionOutputRefCon: ref)
            let status = VTDecompressionSessionCreate(
                allocator: nil, formatDescription: desc,
                decoderSpecification: decoderSpec,
                imageBufferAttributes: attrs, outputCallback: &record,
                decompressionSessionOut: &newSession)
            if status == noErr { session = newSession }
        }
    }

    private func enqueue(_ packet: PLNS.Packet) {
        guard let format else { return }
        let units = annexBParser.split(packet.payload)
        guard !units.isEmpty else { return }
        // Annex-B -> AVCC (4-byte big-endian lengths，純算術組，避免 withUnsafeBytes(of:) 變異)。
        var avcc = Data()
        for unit in units {
            let n = UInt32(unit.count)
            avcc.append(contentsOf: [UInt8(n >> 24), UInt8((n >> 16) & 0xff),
                                     UInt8((n >> 8) & 0xff), UInt8(n & 0xff)])
            avcc.append(unit)
        }
        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: avcc.count, flags: 0,
            blockBufferOut: &blockBuffer)
        guard let blockBuffer else { return }
        avcc.withUnsafeBytes { raw in
            if let base = raw.bindMemory(to: UInt8.self).baseAddress {
                CMBlockBufferReplaceDataBytes(
                    with: base, blockBuffer: blockBuffer,
                    offsetIntoDestination: 0, dataLength: avcc.count)
            }
        }
        var size = avcc.count
        var timing = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(max(0, packet.ptsUs)),
                                          timescale: 1_000_000),
            decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: blockBuffer, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sampleBuffer)
        guard let sampleBuffer else { return }
        guard let session else { return }
        var flags = VTDecodeInfoFlags()
        // Frames are emitted through the session's outputCallback (decodeCallback).
        VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sampleBuffer, flags: [],
            infoFlagsOut: &flags, outputHandler: { _, _, _, _, _ in })
    }
}

private final class AnnexBSplitter {
    func split(_ data: Data) -> [Data] {
        var units: [Data] = []
        var current = Data()
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            if i + 3 < bytes.count, bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                if !current.isEmpty { units.append(current); current = Data() }
                i += 3
            } else if i + 4 <= bytes.count, bytes[i] == 0, bytes[i + 1] == 0,
                      bytes[i + 2] == 0, bytes[i + 3] == 1 {
                if !current.isEmpty { units.append(current); current = Data() }
                i += 4
            } else {
                current.append(bytes[i])
                i += 1
            }
        }
        if !current.isEmpty { units.append(current) }
        return units.filter { !$0.isEmpty }
    }
}

// MARK: - App

final class PhoneLensHost: NSObject, NSApplicationDelegate, DecodedFrameSink {
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var statusLabel: NSTextField?
    let parser = PLNSParser()
    let decoder = H264Sink()
    private let slot = SlotWriter()
    private var stateText = "等待 USB 連線…"
    private let extID = "tw.phonecamera.phonelens.frame"

    func externalStatus(_ text: String) { updateStatus(text) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "📷 PhoneLens"
        statusItem?.menu = buildMenu()
        decoder.setSink(self)
        refreshMenu()
        // Headless trigger for automation: `touch /tmp/plc-activate-now`
        // then relaunch, and the app submits the activation request itself.
        if FileManager.default.fileExists(atPath: "/tmp/plc-activate-now") {
            try? FileManager.default.removeItem(atPath: "/tmp/plc-activate-now")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.activateExtension()
            }
        }
        // NOTE: activation is user-triggered from the window button
        // ("安裝／啟用虛擬攝影機…"). Auto-activating on every launch
        // re-prompts and races the tunnel loop.
    }

    private func buildWindow() {
        let label = NSTextField(labelWithString: stateText)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byWordWrapping
        label.frame = NSRect(x: 20, y: 80, width: 360, height: 60)
        statusLabel = label
        let button = NSButton(title: "安裝／啟用虛擬攝影機…", target: self,
                              action: #selector(activateExtension))
        button.bezelStyle = .rounded
        button.frame = NSRect(x: 20, y: 30, width: 220, height: 30)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 160))
        view.addSubview(label)
        view.addSubview(button)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
                          styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window?.title = "Phone Lens Camera"
        window?.contentView = view
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: DecodedFrameSink

    func decodedFrame(_ pixelBuffer: CVPixelBuffer) {
        slot.publish(pixelBuffer)
    }

    // MARK: menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let state = NSMenuItem(title: stateText, action: nil, keyEquivalent: "")
        state.tag = 1
        menu.addItem(state)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "重新連接 iPhone", action: #selector(reconnect),
                                keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "安裝／啟用虛擬攝影機…", action: #selector(activateExtension),
                                keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "結束 Phone Lens Camera", action: #selector(quit),
                                keyEquivalent: ""))
        for item in menu.items { item.target = self }
        return menu
    }

    private func refreshMenu() {
        DispatchQueue.main.async { [self] in
            statusItem?.menu?.item(withTag: 1)?.title = stateText
            statusItem?.button?.title = stateText.contains("解碼") ? "📷● PhoneLens" : "📷 PhoneLens"
            statusLabel?.stringValue = stateText
        }
    }

    @objc private func reconnect() { /* listenLoop auto-retries; force by closing below */ }

    @objc private func activateExtension() {
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        stateText = "已送出虛擬攝影機啟用請求，請依系統提示允許"
        refreshMenu()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func updateStatus(_ text: String) {
        let line = "\(Date()) \(text)\n"
        let path = "/tmp/phonelens-recv/status.log"
        if FileManager.default.createFile(atPath: path, contents: nil) == false,
           !FileManager.default.fileExists(atPath: path) { /* ignore */ }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        }
        stateText = text
        refreshMenu()
    }
}

// MARK: - System extension activation

extension PhoneLensHost: OSSystemExtensionRequestDelegate {
    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        stateText = "系統要求允許：請到「系統設定」允許 Phone Lens Camera"
        refreshMenu()
    }

    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result) {
        stateText = result == .completed
            ? "虛擬攝影機已啟用：Discord/Zoom 選「Phone Lens Camera」"
            : "虛擬攝影機啟用未完成（\(result.rawValue)）"
        refreshMenu()
    }

    func request(_ request: OSSystemExtensionRequest,
                 didFailWithError error: Error) {
        stateText = "虛擬攝影機啟用失敗：\(error.localizedDescription)"
        refreshMenu()
    }
}

final class HostApp: NSObject, NSApplicationDelegate {
    private var host = PhoneLensHost()

    func applicationDidFinishLaunching(_ notification: Notification) {
        host.applicationDidFinishLaunching(notification)
        startTunnelLoop()
    }

    func startTunnelLoop() {
        DispatchQueue.global(qos: .userInitiated).async { self.listenLoop() }
    }

    /// Keeps retrying: discover a USB iPhone via usbmuxd Listen, then open a
    /// raw tunnel. usbmuxd re-delivers Attached events per connection, so a
    /// fresh Listen after every disconnect doubles as the reconnect loop.
    private func listenLoop() {
        while true {
            do {
                let device = try waitForAttachedDevice()
                host.externalStatus("找到 iPhone（serial \(device.serial)）· 連線中…")
                try runTunnel(device: device)
            } catch MuxError.noDevice {
                host.externalStatus("找不到 USB 連接的 iPhone；請插上 USB 線並信任此 Mac")
                Thread.sleep(forTimeInterval: 1)
            } catch {
                host.externalStatus("連線失敗：\(error)")
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    private func waitForAttachedDevice() throws -> (id: Int, serial: String) {
        let socket = MuxSocket()
        try socket.open()
        defer { socket.close() }
        guard let listen = MuxMessage.plist(
            ["MessageType": "Listen", "kLibUSBmuxdVersion": 2,
             "ClientVersionString": "PhoneLensReceiver"],
            type: MuxMessageType.plistData, tag: 1) else {
            throw MuxError.connectFailed("無法產生 Listen 訊息")
        }
        try socket.send(listen)
        while true {
            let (type, plist) = try socket.receive()
            guard type == MuxMessageType.plistData,
                  let plist, (plist["MessageType"] as? String) == "Attached" else { continue }
            let deviceID = plist["DeviceID"] as? Int ?? -1
            let props = plist["Properties"] as? [String: Any]
            let serial = props?["SerialNumber"] as? String ?? "?"
            let connectionType = props?["ConnectionType"] as? String ?? "USB"
            guard deviceID >= 0, connectionType == "USB" else { continue }
            return (deviceID, serial)
        }
    }

    /// Raw tunnel: Connect to the phone's PLNS port; on Result==0 the same
    /// socket becomes a pipe into the phone's TCP server.
    private func runTunnel(device: (id: Int, serial: String)) throws {
        let socket = MuxSocket()
        try socket.open()
        defer { socket.close() }
        // usbmuxd expects the port in network byte order packed as u32
        // (libusbmuxd calls htons before storing).
        let port = UInt32(UInt16(8765).bigEndian)
        guard let connect = MuxMessage.plist(
            ["MessageType": "Connect", "DeviceID": device.id, "PortNumber": port],
            type: MuxMessageType.plistData, tag: 2) else {
            throw MuxError.connectFailed("無法產生 Connect 訊息")
        }
        try socket.send(connect)
        let (type, plist) = try socket.receive()
        guard type == MuxMessageType.result || type == MuxMessageType.plistData,
              let dict = plist, (dict["MessageType"] as? String) == "Result" else {
            throw MuxError.shortRead
        }
        let number = dict["Number"] as? Int ?? -1
        guard number == 0 else { throw MuxError.badResult(number) }
        host.externalStatus("已連線 iPhone · 等待串流…")
        let fd = socket.fd
        let bufferSize = 256 * 1024
        var readBuffer = [UInt8](repeating: 0, count: bufferSize)
        var byteTotal = 0
        var kindCount: [UInt8: Int] = [:]
        var lastReport = Date()
        var totalPackets = 0
        while true {
            let n = readBuffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int in
                Darwin.recv(fd, raw.baseAddress!, bufferSize, 0)
            }
            guard n > 0 else { host.externalStatus("手機端串流已停止"); return }
            byteTotal += n
            let chunk = Data(readBuffer[0..<n])
            for packet in host.parser.feed(chunk) {
                host.decoder.handle(packet)
                kindCount[packet.kind, default: 0] += 1
                if packet.kind == PLNS.kindConfig {
                    host.externalStatus("已連線 iPhone · 收到 H.264 參數集，解碼中")
                } else {
                    totalPackets += 1
                    if totalPackets % 30 == 1 {
                        host.externalStatus("已連線 iPhone · 解碼中 · 影格 \(totalPackets) (\(byteTotal) bytes)")
                    }
                }
            }
            if Date().timeIntervalSince(lastReport) >= 2 {
                lastReport = Date()
                let kinds = kindCount.sorted { $0.key < $1.key }
                    .map { "kind\($0.key)=\($0.value)" }.joined(separator: " ")
                host.externalStatus("隧道有流量 · \(byteTotal) bytes · \(kinds)")
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let app = NSApplication.shared
let delegate = HostApp()
// Entry point lives in main.swift (@main).
