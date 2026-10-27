// Writes the latest decoded frame's IOSurface ID into the App Group slot.
// The camera extension reads this slot on its 60Hz pump and feeds its CMIO
// stream. Letterbox 1080x1440 portrait into 1920x1440 landscape.
import CoreImage
import CoreVideo
import Foundation
import IOSurface

final class SlotWriter {
    private struct Slot: Codable {
        var surfaceID: UInt32
        var width: Int32
        var height: Int32
        var sequence: Int64
        var hostTimeNs: UInt64
    }

    private let outWidth = 1920
    private let outHeight = 1440
    private var outBuffer: CVPixelBuffer?
    private var ciContext: CIContext?
    private var sequence: Int64 = 0
    private let slotURL: URL?

    init() {
        slotURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier:
                "SRFBVL8ZLU.tw.phonecamera.phonelens")?
            .appendingPathComponent("latest.plist")
        ciContext = CIContext(options: [.useSoftwareRenderer: false])
    }

    /// Composite the portrait frame centered on a black 1920x1440 surface and
    /// publish its IOSurface ID. Runs on the decode queue.
    func publish(_ frame: CVPixelBuffer) {
        let inW = CVPixelBufferGetWidth(frame)
        let inH = CVPixelBufferGetHeight(frame)
        guard inW > 0, inH > 0 else { return }
        let surface = ensureOutput()
        guard let surface else { return }
        // Core Image letterbox: scale portrait to fit height, center X.
        let scale = CGFloat(outHeight) / CGFloat(inH)
        let drawW = CGFloat(inW) * scale
        let dx = (CGFloat(outWidth) - drawW) / 2
        guard let ctx = ciContext else { return }
        var inBuffer = frame
        // CIImage from the VideoToolbox buffer (IOSurface-backed, zero copy).
        let image = CIImage(cvPixelBuffer: inBuffer)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: dx, y: 0))
        CVPixelBufferLockBaseAddress(surface, [])
        // Clear to black first (letterbox bars).
        if let base = CVPixelBufferGetBaseAddress(surface) {
            memset(base, 0,
                   CVPixelBufferGetBytesPerRow(surface) *
                   CVPixelBufferGetHeight(surface))
        }
        ctx.render(image, to: surface)
        CVPixelBufferUnlockBaseAddress(surface, [])
        // Publish the slot.
        sequence += 1
        guard let unmanaged = CVPixelBufferGetIOSurface(surface),
              let slotURL else { return }
        let ioSurface = unmanaged.takeUnretainedValue()
        let slot = Slot(surfaceID: IOSurfaceGetID(ioSurface),
                        width: Int32(outWidth), height: Int32(outHeight),
                        sequence: sequence,
                        hostTimeNs: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        if let data = try? PropertyListEncoder().encode(slot) {
            try? data.write(to: slotURL, options: .atomic)
        }
    }

    private func ensureOutput() -> CVPixelBuffer? {
        if let outBuffer,
           CVPixelBufferGetWidth(outBuffer) == outWidth,
           CVPixelBufferGetHeight(outBuffer) == outHeight {
            return outBuffer
        }
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                     kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(nil, outWidth, outHeight,
                                  kCVPixelFormatType_32BGRA, attrs,
                                  &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        outBuffer = buffer
        return buffer
    }
}
