import Combine
import CoreVideo
import Foundation
import Network

/// PLNS server for the USB tunnel. The phone LISTENS on loopback 8765 and the
/// desktop side forwards through usbmuxd (macOS: built-in `usbmuxd` + receiver
/// tool; Windows: `iproxy 8765 8765`, since Lightning USB has no IP interface).
/// Wire semantics mirror the Android `UsbTunnelWriter`: a 12-frame bounded
/// queue that drops stale access units, keyframe-priority clearing, CONFIG
/// replay on every (re)connect, and KEEP_ALIVE when idle.
final class StreamServer: ObservableObject {
    static let port: UInt16 = 8765
    static let maxQueueFrames = 12

    @Published private(set) var stateText = "未啟動串流"
    @Published private(set) var clientConnected = false
    /// True between start() and stop(); drives isIdleTimerDisabled so the
    /// screen (and the loopback listener) stays alive while streaming.
    @Published private(set) var isStreaming = false
    @Published private(set) var sentFPS = 0
    @Published private(set) var sentKbps = 0
    @Published private(set) var lastError: String?
    @Published private(set) var renderedFPS = 0
    @Published private(set) var encoderPackets = 0

    private let queue = DispatchQueue(label: "tw.phonecamera.phonelens.stream")
    private let encoder = H264StreamEncoder()
    private var listener: NWListener?
    private var connection: NWConnection?
    private var pending: [Data] = []
    private var sending = false
    private var latestConfig: Data?
    private var keepAliveTimer: DispatchSourceTimer?
    private var statsFrameCount = 0
    private var statsByteCount = 0
    private var statsLast = Date()
    private var configResendTick = 0
    private var renderedFrameCount = 0
    /// Frames handed to the encoder but awaiting the renderer's stream frames.
    private var streamActive = false

    func start() {
        queue.async { self.startLocked() }
    }

    func stop() {
        queue.async { self.stopLocked() }
    }

    private func startLocked() {
        guard listener == nil else { return }
        streamActive = true
        isStreaming = true
        let params = NWParameters.tcp
        let port = NWEndpoint.Port(rawValue: Self.port) ?? 8765
        // Only constrain the listener to loopback. Setting requiredLocalEndpoint
        // on the listener leaks to accepted connections, which then try to
        // re-bind the same 127.0.0.1:8765 and get reset (errno 54).
        params.requiredInterfaceType = .loopback
        guard let newListener = try? NWListener(using: params, on: port) else {
            lastError = "無法監聽 127.0.0.1:\(Self.port)"
            setState("串流失敗")
            return
        }
        listener = newListener
        newListener.newConnectionHandler = { [weak self] connection in
            self?.queue.async { self?.accept(connection) }
        }
        newListener.stateUpdateHandler = { [weak self] state in
            self?.queue.async {
                switch state {
                case .ready:
                    self?.setState("監聽 127.0.0.1:\(Self.port) · 等待電腦（usbmux 轉送）")
                case .failed(let error):
                    self?.lastError = "監聽失敗：\(error.localizedDescription)"
                    self?.setState("串流失敗")
                default: break
                }
            }
        }
        newListener.start(queue: queue)
        let width = 1080, height = 1440
        encoder.start(width: width, height: height, bitrate: 6_000_000, fps: 30) { [weak self] packet in
            self?.queue.async { self?.handle(packet) }
        }
        setState("準備串流 · 等待第一幀")
    }

    private func stopLocked() {
        streamActive = false
        isStreaming = false
        encoder.stop()
        listener?.cancel()
        listener = nil
        connection?.cancel()
        connection = nil
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        pending.removeAll()
        sending = false
        latestConfig = nil
        clientConnected = false
        sentFPS = 0
        sentKbps = 0
        renderedFPS = 0
        encoderPackets = 0
        renderedFrameCount = 0
        configResendTick = 0
        setState("未啟動串流")
    }

    private func setState(_ text: String) {
        stateText = text
    }

    private func accept(_ newConnection: NWConnection) {
        connection?.cancel()
        pending.removeAll()
        sending = false
        connection = newConnection
        clientConnected = true
        setState("已連線電腦 · 傳送中")
        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            self?.queue.async {
                // A stale connection's state must not clobber a newer one: the
                // listener cancels the previous connection on each accept, and
                // its delayed .cancelled would otherwise wipe the live client.
                guard let self, let newConnection, self.connection === newConnection else {
                    return
                }
                if case .failed(let error) = state {
                    self.lastError = "連線錯誤：\(error.localizedDescription)"
                    self.dropClient()
                }
                if case .cancelled = state { self.dropClient() }
                if case .ready = state {
                    // latestConfig is already a fully encoded CONFIG packet
                    // (see handle:); send it as-is. Re-encoding it here would
                    // nest one packet inside another and the receiver would
                    // never extract SPS/PPS from it.
                    if let latestConfig = self.latestConfig {
                        self.pending.insert(latestConfig, at: 0)
                    }
                    self.drain()
                }
            }
        }
        // A listener-accepted NWConnection starts in .setup; it only reaches
        // .ready after start(_:) is called. Until then every guarded send is
        // skipped and the tunnel looks silent on the desktop side.
        newConnection.start(queue: queue)
        // Drain any inbound bytes (receivers do not send data on this protocol).
        receiveLoop(newConnection)
        encoder.requestKeyframe()
        keepAliveTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.sendKeepAliveIfNeeded() }
        timer.resume()
        keepAliveTimer = timer
    }

    private func dropClient() {
        connection = nil
        clientConnected = false
        pending.removeAll()
        sending = false
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        if streamActive { setState("監聽 127.0.0.1:\(Self.port) · 等待電腦（usbmux 轉送）") }
        encoder.requestKeyframe()
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, error in
            guard let self else { return }
            if error == nil, data != nil {
                self.receiveLoop(connection)
            } else {
                self.queue.async { self.dropClient() }
            }
        }
    }

    /// Called from the encoder sink on `queue`.
private func handle(_ packet: StreamProtocol.Packet) {
        guard streamActive else { return }
        if packet.kind == .config {
            latestConfig = StreamProtocol.encode(packet)
            encoderPackets += 1
            return
        }
        encoderPackets += 1
        let encoded = StreamProtocol.encode(packet)
        statsFrameCount += 1
        statsByteCount += encoded.count
        if pending.count >= Self.maxQueueFrames {
            guard packet.keyFrame else { return } // drop stale non-keyframe
            pending.removeAll()                   // keyframe clears the queue
        }
        pending.append(encoded)
        drain()
    }

    private func drain() {
        guard !sending, let connection else { return }
        guard connection.state == .ready else { return }
        guard !pending.isEmpty else { return }
        sending = true
        let data = pending.removeFirst()
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                self.sending = false
                if error != nil { self.dropClient(); return }
                self.drain()
            }
        })
    }

    private func sendNow(_ data: Data) {
        guard let connection, connection.state == .ready else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil { self.queue.async { self.dropClient() } }
        })
    }

    private func sendKeepAliveIfNeeded() {
        guard connection?.state == .ready else { return }
        if !sending && pending.isEmpty {
            sendNow(StreamProtocol.encode(StreamProtocol.Packet(kind: .keepAlive)))
        }
        let now = Date()
        let seconds = max(0.001, now.timeIntervalSince(statsLast))
        if seconds >= 1 {
            sentFPS = Int((Double(statsFrameCount) / seconds).rounded())
            sentKbps = Int((Double(statsByteCount) * 8 / seconds / 1000).rounded())
            renderedFPS = Int((Double(renderedFrameCount) / seconds).rounded())
            if let encoderError = encoder.errorText() { lastError = encoderError }
            statsFrameCount = 0
            statsByteCount = 0
            renderedFrameCount = 0
            statsLast = now
            // Receivers that join mid-stream (or miss the one-shot CONFIG)
            // would otherwise stay format-less forever: re-announce the
            // parameter sets every ~2s. 24 + SPS/PPS bytes is negligible.
            configResendTick += 1
            if configResendTick % 2 == 0, let latestConfig {
                pending.insert(latestConfig, at: 0)
                drain()
            }
        }
    }

    // MARK: renderer feed

    /// Called by ContentView after the renderer exists; hands rendered frames
    /// to the encoder. No-op while streaming is not active.
    func deliverFrame(_ pixelBuffer: CVPixelBuffer) {
        queue.async { [weak self] in
            guard let self, self.streamActive else { return }
            self.renderedFrameCount += 1
            let timeUs = Int64(DispatchTime.now().uptimeNanoseconds / 1000)
            self.encoder.encode(pixelBuffer, presentationTimeUs: timeUs)
        }
    }

}
