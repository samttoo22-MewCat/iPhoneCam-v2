// PhoneLensCamera IPC contract between the host app and the camera extension.
// The host app decodes PLNS/H.264 into IOSurface-backed CVPixelBuffers and
// hands the IOSurface IDs to the extension over a Mach service. The
// extension wraps them back into pixel buffers and feeds its CMIO stream.
// IOSurface IDs are process-scoped handles to kernel objects; sending the
// raw ID plus width/height over the Mach message is sufficient on the
// same machine (both ends are sandboxed but share the kernel registry).
import Foundation

enum FrameIPC {
    /// Mach service name advertised by the camera extension.
    static let machServiceName = "tw.phonecamera.phonelens.frame"
    /// App group shared by host app and extension (written with the team prefix).
    static let appGroupID = "GROUP_TW_PHONECAMERA_PHONELENS"
    /// Latest-frame slot in the group container (`latest.plist`).
    static let slotFileName = "latest.plist"
    /// Stream geometry published to clients (letterboxed landscape).
    static let outWidth = 1920
    static let outHeight = 1440
    static let outFPS: Int32 = 30
}
