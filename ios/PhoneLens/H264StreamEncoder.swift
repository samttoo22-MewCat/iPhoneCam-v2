import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Hardware H.264 encoder (VideoToolbox) that emits PLNS packets.
/// Input is the beauty-processed BGRA pixel buffer produced by BeautyRenderer;
/// output access units are Annex-B. CONFIG (SPS+PPS) is emitted when the
/// parameter sets change and is replayed by the server on reconnect,
/// mirroring the Android `H264Encoder` + `UsbTunnelWriter` contract.
final class H264StreamEncoder {
    typealias Sink = (StreamProtocol.Packet) -> Void

    private var session: VTCompressionSession?
    private let queue = DispatchQueue(label: "tw.phonecamera.phonelens.encoder")
    private var sink: Sink?
    private var sequence: Int32 = 0
    private var lastConfig: Data?
    private var streamWidth = 0
    private var streamHeight = 0
    private var streamBitrate = 6_000_000
    private var streamFPS = 30
    private var requestKeyFrame = false
    private(set) var lastError: String?

    func start(width: Int, height: Int, bitrate: Int, fps: Int, sink: @escaping Sink) {
        queue.sync {
            self.sink = sink
            streamWidth = width
            streamHeight = height
            streamBitrate = bitrate
            streamFPS = fps
            setupLocked(width: width, height: height, bitrate: bitrate, fps: fps)
        }
    }

    func stop() {
        queue.sync {
            if let session { VTCompressionSessionInvalidate(session) }
            session = nil
            sink = nil
            lastConfig = nil
            streamWidth = 0
            streamHeight = 0
            sequence = 0
            requestKeyFrame = false
            lastError = nil
        }
    }

    /// The next encoded frame must be a keyframe (after a client reconnects).
    func requestKeyframe() {
        queue.sync { requestKeyFrame = true }
    }

    func errorText() -> String? {
        queue.sync { lastError }
    }

    func encode(_ pixelBuffer: CVPixelBuffer, presentationTimeUs: Int64) {
        queue.async { [weak self] in
            guard let self, let session = self.session else { return }
            let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
            if w != self.streamWidth || h != self.streamHeight {
                VTCompressionSessionInvalidate(session)
                self.session = nil
                self.lastConfig = nil
                self.streamWidth = w
                self.streamHeight = h
                self.setupLocked(width: w, height: h, bitrate: self.streamBitrate, fps: self.streamFPS)
                guard let session = self.session else { return }
            }
            var props: CFDictionary?
            var frameProps: [CFString: Any] = [:]
            if self.requestKeyFrame {
                frameProps[kVTEncodeFrameOptionKey_ForceKeyFrame] = true as CFBoolean
                props = frameProps as CFDictionary
                self.requestKeyFrame = false
            }
            var flags: VTEncodeInfoFlags = []
            let ref = Unmanaged.passUnretained(self).toOpaque()
            let status = VTCompressionSessionEncodeFrame(
                session, imageBuffer: pixelBuffer,
                presentationTimeStamp: CMTime(value: presentationTimeUs, timescale: 1_000_000),
                duration: .invalid, frameProperties: props,
                sourceFrameRefcon: ref, infoFlagsOut: &flags)
            if status != noErr { self.lastError = "VTCompressionSessionEncodeFrame \(status)" }
        }
    }

    // MARK: internals (queue-confined except the VT callback)

    private func setupLocked(width: Int, height: Int, bitrate: Int, fps: Int) {
        var session: VTCompressionSession?
        let ref = Unmanaged.passUnretained(self).toOpaque()
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { callbackRefCon, _, _, _, sampleBuffer in
                guard let sampleBuffer, let callbackRefCon else { return }
                let encoder = Unmanaged<H264StreamEncoder>.fromOpaque(callbackRefCon).takeUnretainedValue()
                encoder.handleOutput(sampleBuffer)
            },
            refcon: ref,
            compressionSessionOut: &session)
        guard status == noErr, let session else {
            lastError = "VTCompressionSessionCreate \(status)"
            return
        }
        self.session = session
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: fps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: fps * 2 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    /// Runs on the VideoToolbox output callback thread.
    private func handleOutput(_ sampleBuffer: CMSampleBuffer) {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        var spsPtr: UnsafePointer<UInt8>?
        var ppsPtr: UnsafePointer<UInt8>?
        var spsSize = 0, ppsSize = 0, count = 0
        var nalHeader: Int32 = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                desc, parameterSetIndex: 0, parameterSetPointerOut: &spsPtr,
                parameterSetSizeOut: &spsSize, parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: &nalHeader) == noErr,
              CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                desc, parameterSetIndex: 1, parameterSetPointerOut: &ppsPtr,
                parameterSetSizeOut: &ppsSize, parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: &nalHeader) == noErr,
              let spsPtr, let ppsPtr else { return }
        let config = StreamProtocol.joinAnnexB([
            Data(bytes: spsPtr, count: Int(spsSize)),
            Data(bytes: ppsPtr, count: Int(ppsSize))
        ])
        if config != lastConfig {
            lastConfig = config
            sink?(StreamProtocol.Packet(kind: .config, payload: config))
        }
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let total = CMBlockBufferGetDataLength(dataBuffer)
        var bytes = [UInt8](repeating: 0, count: total)
        CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: total, destination: &bytes)
        var annexB = Data()
        var offset = 0
        while offset + 4 <= total {
            let length = (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16) |
                (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
            guard length > 0, offset + 4 + length <= total else { break }
            annexB.append(contentsOf: StreamProtocol.annexBStartCode())
            annexB.append(contentsOf: bytes[(offset + 4)..<(offset + 4 + length)])
            offset += 4 + length
        }
        guard !annexB.isEmpty else { return }
        // Keyframe detection: check the FIRST NAL unit's type (5 = IDR).
        // The old check scanned every payload byte for value 5, which flags
        // nearly all frames as keyframes and breaks keyframe-priority queueing.
        let ab = [UInt8](annexB)
        var nalStart = 0
        if ab.count > 4, ab[0] == 0, ab[1] == 0 {
            if ab[2] == 1 { nalStart = 3 }
            else if ab[2] == 0, ab.count > 4, ab[3] == 1 { nalStart = 4 }
        }
        let isKeyFrame = nalStart < ab.count && (ab[nalStart] & 0x1F) == 5
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        sequence &+= 1
        sink?(StreamProtocol.Packet(kind: .accessUnit, keyFrame: isKeyFrame,
                                    sequence: sequence,
                                    presentationTimeUs: Int64(max(0, pts * 1_000_000)),
                                    payload: annexB))
    }
}
