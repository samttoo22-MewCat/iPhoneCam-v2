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

private enum PLNS {
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

private final class PLNSParser {
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

private final class H264Sink: NSObject {
    static let shared = H264Sink()
    let layer = AVSampleBufferDisplayLayer()
    private let queue = DispatchQueue(label: "tw.phonecamera.receiver.decode")
    private var format: CMVideoFormatDescription?
    private let annexBParser = AnnexBSplitter()
    private var session: VTDecompressionSession?
    private var decodeCount = 0
    private var presentedCount = 0
    private var rawFormat: CMVideoFormatDescription?

    /// Lightweight content-liveness probe: decode in the background and hash
    /// a sample of pixels. If hashes change over time, the phone is sending
    /// live content and any freeze is in the display path.
    private let decodeCallback: VTDecompressionOutputCallback = {
        (refCon, _, status, _, imageBuffer, _, _) in
        guard status == noErr, let imageBuffer,
              let refCon else { return }
        let holder = Unmanaged<LivenessBox>.fromOpaque(refCon).takeUnretainedValue()
        holder.didDecode(imageBuffer)
    }

    private final class LivenessBox {
        var count = 0
        var submitErrLogged = false
        var outputErrLogged = false
        func noteSubmitError(_ st: OSStatus) {
            guard !submitErrLogged else { return }
            submitErrLogged = true
            fputs("PhoneLensReceiver DIAG decode SUBMIT failed status=\(st)\n", stderr)
        }
        func noteOutputError(_ st: OSStatus) {
            guard !outputErrLogged else { return }
            outputErrLogged = true
            fputs("PhoneLensReceiver DIAG decode OUTPUT failed status=\(st)\n", stderr)
        }
        func didDecode(_ buffer: CVImageBuffer) {
            count += 1
            guard count % 120 == 1 else { return }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            let h = CVPixelBufferGetHeight(buffer)
            var hash: UInt64 = 146959
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            var y = 0
            while y < h {
                var x = 0
                while x < 64 {
                    hash = (hash ^ UInt64(ptr[y * bytesPerRow + x])) &* 1099511628211
                    x += 7
                }
                y += 37
            }
            fputs("PhoneLensReceiver DIAG content hash=\(String(hash, radix: 16)) frame=\(count)\n", stderr)
        }
    }
    private let livenessBox = LivenessBox()

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

    private var enqueuedCount = 0
    private var createFailCount = 0
    private var lastDiag = Date()

    private func diag(_ text: String) {
        fputs("PhoneLensReceiver DIAG \(text)\n", stderr)
    }

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
            // Background liveness decoder (content hash only, never displayed).
            session.map(VTDecompressionSessionInvalidate)
            session = nil
            let attrs: NSDictionary = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
            ]
            let ref = Unmanaged.passUnretained(livenessBox).toOpaque()
            var record = VTDecompressionOutputCallbackRecord(
                decompressionOutputCallback: nil,
                decompressionOutputRefCon: ref)
            var newSession: VTDecompressionSession?
            let spec: NSDictionary = [
                kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
            ]
            if VTDecompressionSessionCreate(
                allocator: nil, formatDescription: desc,
                decoderSpecification: spec, imageBufferAttributes: attrs,
                outputCallback: &record,
                decompressionSessionOut: &newSession) == noErr {
                session = newSession
                // Decoded-frame format for presentation: raw BGRA at the
                // stream dimensions, same path as the proven test pattern.
                let dims = CMVideoFormatDescriptionGetDimensions(desc)
                var rawDesc: CMVideoFormatDescription?
                if CMVideoFormatDescriptionCreate(
                    allocator: nil, codecType: kCVPixelFormatType_32BGRA,
                    width: dims.width, height: dims.height, extensions: nil,
                    formatDescriptionOut: &rawDesc) == noErr {
                    rawFormat = rawDesc
                }
                diag("liveness VT session created \(dims.width)x\(dims.height)")
            } else {
                diag("liveness VT session CREATE FAILED")
            }
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
        let createStatus = CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: blockBuffer, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sampleBuffer)
        guard createStatus == noErr, let sampleBuffer else {
            createFailCount += 1
            if createFailCount % 30 == 1 {
                diag("CMSampleBufferCreateReady failed status=\(createStatus) count=\(createFailCount)")
            }
            return
        }
        // Decode here and present the DECODED BGRA frame (same path as the
        // proven test pattern). Feeding compressed sample buffers straight
        // to the layer left it stuck on a stale frame.
        if let session {
            var flags = VTDecodeInfoFlags()
            let box = self.livenessBox
            let ds = VTDecompressionSessionDecodeFrame(
                session, sampleBuffer: sampleBuffer, flags: [],
                infoFlagsOut: &flags,
                outputHandler: { [weak self] status, _, imageBuffer, _, _ in
                    guard status == noErr, let imageBuffer else {
                        box.noteOutputError(status)
                        return
                    }
                    box.didDecode(imageBuffer)
                    self?.presentDecoded(imageBuffer)
                })
            if ds != noErr { box.noteSubmitError(ds) }
        }
    }

    /// Wraps a decoded BGRA buffer with host-clock timing and presents it on
    /// the main thread — identical to the working synthetic test pattern.
    private var rawFormatKey = ""
    private var blitBuffer: CVPixelBuffer?
    private func rawFormatFor(_ buffer: CVImageBuffer) -> CMVideoFormatDescription? {
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let px = CVPixelBufferGetPixelFormatType(buffer)
        let key = "\(w)x\(h)-\(String(format: "%08x", px))"
        if key == rawFormatKey, let rawFormat { return rawFormat }
        var desc: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: px, width: Int32(w), height: Int32(h),
            extensions: nil, formatDescriptionOut: &desc) == noErr,
              let desc else {
            diag("rawFormatFor: create failed \(key)")
            return nil
        }
        rawFormat = desc
        rawFormatKey = key
        blitBuffer = nil // dimensions may have changed; recreate below
        diag("rawFormat now \(key)")
        return desc
    }

    private func presentDecoded(_ imageBuffer: CVImageBuffer) {
        // Bit-exact CPU copy into our own buffer (same kind as the working
        // synthetic frames), then wrap + present. Direct wrapping of the
        // VideoToolbox pool buffer fails with -12743 on this toolchain.
        let w = CVPixelBufferGetWidth(imageBuffer)
        let h = CVPixelBufferGetHeight(imageBuffer)
        if blitBuffer == nil
            || CVPixelBufferGetWidth(blitBuffer!) != w
            || CVPixelBufferGetHeight(blitBuffer!) != h {
            var fresh: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                                      nil, &fresh) == kCVReturnSuccess,
                  let fresh else {
                diag("presentDecoded: blit buffer create failed")
                return
            }
            blitBuffer = fresh
        }
        guard let blit = blitBuffer else { return }
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(blit, [])
        let srcRow = CVPixelBufferGetBytesPerRow(imageBuffer)
        let dstRow = CVPixelBufferGetBytesPerRow(blit)
        if let src = CVPixelBufferGetBaseAddress(imageBuffer),
           let dst = CVPixelBufferGetBaseAddress(blit) {
            let copyRow = min(srcRow, dstRow)
            for y in 0..<h {
                memcpy(dst.advanced(by: y * dstRow),
                       src.advanced(by: y * srcRow), copyRow)
            }
        }
        CVPixelBufferUnlockBaseAddress(blit, [])
        CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly)
        guard let rawFormat = rawFormatFor(blit) else {
            diag("presentDecoded: no rawFormat")
            return
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var sbuf: CMSampleBuffer?
        let cs = CMSampleBufferCreateForImageBuffer(
            allocator: nil, imageBuffer: blit, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil,
            formatDescription: rawFormat, sampleTiming: &timing,
            sampleBufferOut: &sbuf)
        guard cs == noErr, let sbuf else {
            diag("presentDecoded: wrap failed status=\(cs)")
            return
        }
        presentedCount += 1
        if presentedCount % 120 == 1 {
            diag("presented decoded frame=\(presentedCount)")
        }
        let layer = self.layer
        DispatchQueue.main.async { layer.enqueue(sbuf) }
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

private final class VideoView: NSView {
    override var wantsLayer: Bool {
        get { true }
        set {}
    }

    override func makeBackingLayer() -> CALayer {
        H264Sink.shared.layer
    }

    override func layout() {
        super.layout()
        H264Sink.shared.layer.frame = bounds
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var statusLabel: NSTextField!
    private let parser = PLNSParser()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let video = VideoView()
        video.autoresizingMask = [.width, .height]
        statusLabel = NSTextField(labelWithString: "等待 USB 連線…")
        statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.autoresizingMask = [.width]
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 960))
        container.wantsLayer = true
        video.frame = container.bounds
        container.addSubview(video)
        statusLabel.frame = NSRect(x: 12, y: container.bounds.height - 30,
                                   width: container.bounds.width - 24, height: 18)
        container.addSubview(statusLabel)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 960),
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        window?.title = "PhoneLens Receiver（iPhone 美顏鏡頭）"
        window?.contentView = container
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateStatus("等待 USB 連線…")
        DispatchQueue.global(qos: .userInitiated).async { self.listenLoop() }
    }

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
        DispatchQueue.main.async {
            self.statusLabel.stringValue = text
        }
    }

    /// Keeps retrying: discover a USB iPhone via usbmuxd Listen, then open a
    /// raw tunnel. usbmuxd re-delivers Attached events per connection, so a
    /// fresh Listen after every disconnect doubles as the reconnect loop.
    private func listenLoop() {
        while true {
            do {
                let device = try waitForAttachedDevice()
                updateStatus("找到 iPhone（serial \(device.serial)）· 連線中…")
                try runTunnel(device: device)
            } catch MuxError.noDevice {
                updateStatus("找不到 USB 連接的 iPhone；請插上 USB 線並信任此 Mac")
                Thread.sleep(forTimeInterval: 1)
            } catch {
                updateStatus("連線失敗：\(error)")
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
        updateStatus("已連線 iPhone · 等待串流…")
        let fd = socket.fd
        // Phone relaunch/kill can orphan this tunnel in a half-open state
        // where recv blocks forever (no EOF from usbmuxd). Bound the wait and
        // recycle the tunnel so a fresh Connect replays CONFIG.
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        withUnsafePointer(to: &tv) {
            $0.withMemoryRebound(to: timeval.self, capacity: 1) {
                _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0,
                                      socklen_t(MemoryLayout<timeval>.size))
            }
        }
        let bufferSize = 256 * 1024
        var readBuffer = [UInt8](repeating: 0, count: bufferSize)
        var byteTotal = 0
        var kindCount: [UInt8: Int] = [:]
        var lastReport = Date()
        var lastData = Date()
        var totalPackets = 0
        while true {
            let n = readBuffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int in
                Darwin.recv(fd, raw.baseAddress!, bufferSize, 0)
            }
            if n == 0 { updateStatus("手機端串流已停止"); return }
            if n < 0 {
                // Timeout (or error): if the tunnel has been silent well past
                // the 1s keep-alive cadence, recycle it; the reconnect
                // replays CONFIG and resumes without user action.
                if Date().timeIntervalSince(lastData) > 5 {
                    updateStatus("隧道逾時，重連…")
                    return
                }
                continue
            }
            lastData = Date()
            byteTotal += n
            let chunk = Data(readBuffer[0..<n])
            for packet in parser.feed(chunk) {
                H264Sink.shared.handle(packet)
                kindCount[packet.kind, default: 0] += 1
                if packet.kind == PLNS.kindConfig {
                    updateStatus("已連線 iPhone · 收到 H.264 參數集，解碼中")
                } else {
                    totalPackets += 1
                    if totalPackets % 30 == 1 {
                        updateStatus("已連線 iPhone · 解碼中 · 影格 \(totalPackets) (\(byteTotal) bytes)")
                    }
                }
            }
            if Date().timeIntervalSince(lastReport) >= 2 {
                lastReport = Date()
                let kinds = kindCount.sorted { $0.key < $1.key }
                    .map { "kind\($0.key)=\($0.value)" }.joined(separator: " ")
                updateStatus("隧道有流量 · \(byteTotal) bytes · \(kinds)")
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let app = NSApplication.shared
private let delegate = AppDelegate()
// Hold a user-initiated activity for the process lifetime: without it macOS
// may App-Nap this background receiver, which stalls the display link while
// packets keep flowing (frozen preview + full layer queue).
private let napInhibitor = ProcessInfo.processInfo.beginActivity(
    options: [.userInitiated, .idleDisplaySleepDisabled],
    reason: "USB camera preview streaming")
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
