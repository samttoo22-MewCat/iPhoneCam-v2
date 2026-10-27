// Phone Lens Camera Extension.
// Publishes "Phone Lens Camera" (1920x1440 BGRA, 30fps). Frames come from
// the host app through an App Group slot: the host decodes PLNS/H.264 into
// an IOSurface-backed pixel buffer and writes its surface ID + geometry;
// the extension looks the surface up and feeds its CMIO stream. Zero copy:
// the IOSurface memory is shared by the kernel between both processes.
import CoreMediaIO
import Foundation
import IOKit.audio
import IOSurface
import os.log

private let kFrameRate: Int = 60
private let kOutWidth: Int32 = 1920
private let kOutHeight: Int32 = 1440

// MARK: - Shared slot

/// Written by the host app, read by the extension (App Group container).
private struct FrameSlot: Codable {
    var surfaceID: UInt32
    var width: Int32
    var height: Int32
    var sequence: Int64
    var hostTimeNs: UInt64
}

private func slotURL() -> URL? {
    // App Group "SRFBVL8ZLU.tw.phonecamera.phonelens" (team ID from the
    // Developer ID used to sign host + extension; matches both entitlements).
    guard let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier:
            "SRFBVL8ZLU.tw.phonecamera.phonelens") else { return nil }
    return container.appendingPathComponent("latest.plist")
}

private func readSlot() -> FrameSlot? {
    guard let url = slotURL(),
          let data = try? Data(contentsOf: url),
          let slot = try? PropertyListDecoder().decode(FrameSlot.self, from: data) else {
        return nil
    }
    return slot
}

// MARK: - Stream source

class PhoneLensCameraStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    private weak var owner: PhoneLensCameraDeviceSource?
    private var videoDescription: CMFormatDescription!
    private var bufferPool: CVPixelBufferPool?
    private var lastSequence: Int64 = -1

    init(localizedName: String, streamID: UUID, device: CMIOExtensionDevice,
         owner: PhoneLensCameraDeviceSource) {
        self.device = device
        self.owner = owner
        super.init()
        var desc: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                       codecType: kCVPixelFormatType_32BGRA,
                                       width: kOutWidth, height: kOutHeight,
                                       extensions: nil, formatDescriptionOut: &desc)
        videoDescription = desc
        let format = CMIOExtensionStreamFormat(
            formatDescription: videoDescription,
            maxFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)),
            minFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)),
            validFrameDurations: nil)
        stream = CMIOExtensionStream(localizedName: localizedName,
                                     streamID: streamID,
                                     direction: .source,
                                     clockType: .hostTime,
                                     source: self)
        do {
            try device.addStream(stream)
        } catch {
            os_log(.error, "addStream failed %{public}@", error.localizedDescription)
        }
        // Black-frame fallback pool (used when the phone is not streaming).
        let attrs: NSDictionary = [
            kCVPixelBufferWidthKey: kOutWidth,
            kCVPixelBufferHeightKey: kOutHeight,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs, &bufferPool)
    }

    var formats: [CMIOExtensionStreamFormat] {
        [CMIOExtensionStreamFormat(
            formatDescription: videoDescription,
            maxFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)),
            minFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)),
            validFrameDurations: nil)]
    }

    var activeFormatIndex: Int = 0 {
        didSet {
            if activeFormatIndex >= 1 {
                os_log(.error, "Invalid format index")
            }
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionStreamProperties {
        let props = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            props.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            props.frameDuration = CMTime(value: 1, timescale: Int32(kFrameRate))
        }
        return props
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let idx = streamProperties.activeFormatIndex {
            activeFormatIndex = idx
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        true
    }

    func startStream() throws {
        guard let source = device.source as? PhoneLensCameraDeviceSource else {
            throw NSError(domain: "PhoneLensCamera", code: -1)
        }
        source.startStreaming()
    }

    func stopStream() throws {
        guard let source = device.source as? PhoneLensCameraDeviceSource else {
            throw NSError(domain: "PhoneLensCamera", code: -1)
        }
        source.stopStreaming()
    }

    func pump() {
        if let slot = readSlot(),
           slot.sequence != lastSequence,
           let surface = IOSurfaceLookup(slot.surfaceID) {
            lastSequence = slot.sequence
            send(surface: surface, hostTimeNs: slot.hostTimeNs)
        } else {
            sendBlack()
        }
    }

    private func send(surface: IOSurfaceRef, hostTimeNs: UInt64) {
        var unmanaged: Unmanaged<CVPixelBuffer>?
        let status = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault, surface, nil, &unmanaged)
        guard status == kCVReturnSuccess, let unmanaged else {
            sendBlack()
            return
        }
        let pixelBuffer = unmanaged.takeRetainedValue()
        var timing = CMSampleTimingInfo()
        timing.presentationTimeStamp = CMTime(value: Int64(hostTimeNs),
                                              timescale: 1_000_000_000)
        var sbuf: CMSampleBuffer?
        let err = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            dataReady: true, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: videoDescription, sampleTiming: &timing,
            sampleBufferOut: &sbuf)
        guard err == noErr, let sbuf else {
            sendBlack()
            return
        }
        stream.send(sbuf, discontinuity: [], hostTimeInNanoseconds: hostTimeNs)
    }

    private func sendBlack() {
        guard let pool = bufferPool else { return }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool,
                                                &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, 0,
                   CVPixelBufferGetBytesPerRow(pixelBuffer) *
                   CVPixelBufferGetHeight(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        var timing = CMSampleTimingInfo()
        timing.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())
        var sbuf: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            dataReady: true, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: videoDescription, sampleTiming: &timing,
            sampleBufferOut: &sbuf) == noErr, let sbuf else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        stream.send(sbuf, discontinuity: [],
                    hostTimeInNanoseconds: UInt64(now.seconds * Double(NSEC_PER_SEC)))
    }
}

// MARK: - Device source

class PhoneLensCameraDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var streamSource: PhoneLensCameraStreamSource!

    private var streamingCounter: UInt32 = 0
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "tw.phonecamera.phonelens.frame",
                                           qos: .userInteractive)

    init(localizedName: String) {
        super.init()
        let deviceID = UUID(uuidString: "8F4A2B1C-3D5E-4F60-8123-456789ABCDEF")!
        device = CMIOExtensionDevice(localizedName: localizedName,
                                     deviceID: deviceID,
                                     legacyDeviceID: nil, source: self)
        let streamID = UUID(uuidString: "1A2B3C4D-5E6F-7081-92A3-B4C5D6E7F809")!
        streamSource = PhoneLensCameraStreamSource(localizedName: "PhoneLens.Video",
                                                   streamID: streamID,
                                                   device: device,
                                                   owner: self)
    }

    func startStreaming() {
        streamingCounter += 1
        guard streamingCounter == 1 else { return }
        timer = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
        timer?.schedule(deadline: .now(), repeating: 1.0 / Double(kFrameRate),
                        leeway: .milliseconds(1))
        timer?.setEventHandler { [weak self] in self?.streamSource.pump() }
        timer?.resume()
    }

    func stopStreaming() {
        if streamingCounter > 1 {
            streamingCounter -= 1
        } else {
            streamingCounter = 0
            timer?.cancel()
            timer = nil
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionDeviceProperties {
        let props = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            props.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            props.model = "Phone Lens Camera"
        }
        return props
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}
}

// MARK: - Provider

class PhoneLensCameraProvider: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: PhoneLensCameraDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = PhoneLensCameraDeviceSource(localizedName: "Phone Lens Camera")
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            os_log(.error, "addDevice failed %{public}@", error.localizedDescription)
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionProviderProperties {
        let props = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            props.manufacturer = "Phone Lens"
        }
        return props
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
