import CoreVideo
import Foundation

/// Swift facade for the open-source wfd face engine
/// (SCRFD detection + 106 landmarks + IoU tracking + head pose),
/// running fully on-device.
///
/// Detection runs on a private serial queue against the latest camera
/// buffer only: slow frames never queue up, matching CameraFrames'
/// latest-slot behavior.
final class FaceEngine {
    enum SetupError: LocalizedError {
        case missingModel(String)
        case engineCreateFailed

        var errorDescription: String? {
            switch self {
            case .missingModel(let name): return "找不到人臉模型：\(name)"
            case .engineCreateFailed: return "人臉引擎無法載入模型"
            }
        }
    }
    struct Face {
        let id: Int32
        let score: Float
        let rect: CGRect               // buffer pixels
        let eyeMid: CGPoint            // avg of the two eye keypoints
        let mouthMid: CGPoint          // avg of the mouth-corner keypoints
        let landmarks: [CGPoint]      // 106 points, buffer pixels
        let yaw: Float
        let pitch: Float
        let roll: Float
        let gender: Int32
        let age: Float
        /// Eye openness, mouth opening, and brow raise from the 106-point mesh.
        let expression: (leftEye: Float, rightEye: Float, mouth: Float, brow: Float)
    }

    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "tw.phonecamera.phonelens.facedetect", qos: .userInteractive)
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var latestSequence = 0
    private var running = false

    /// Faces of the most recent completed detection (thread-safe).
    private(set) var faces: [Face] = []
    /// Called on the detect queue after each processed frame. The sequence is
    /// the camera buffer sequence the faces were computed from.
    var onFaces: (([Face], Int) -> Void)?
    /// Average detect latency in milliseconds (for UI display).
    private(set) var lastMs: Double = 0

    init(detInput: Int32 = 384, threads: Int32 = 3, maxFaces: Int32 = 1) throws {
        guard let det = Bundle.main.path(forResource: "det_10g", ofType: "onnx") else {
            throw SetupError.missingModel("det_10g.onnx")
        }
        guard let lmk = Bundle.main.path(forResource: "2d106det", ofType: "onnx") else {
            throw SetupError.missingModel("2d106det.onnx")
        }
        let detPath = strdup(det)
        let lmkPath = strdup(lmk)
        defer { free(detPath); free(lmkPath) }
        var cfg = wfd_default_config()
        cfg.det_model = UnsafePointer(detPath)
        cfg.lmk_model = UnsafePointer(lmkPath)
        // Age/gender does not affect beauty tracking; do not spend camera-frame
        // budget loading or periodically running this optional model.
        cfg.attr_model = nil
        cfg.det_input_size = detInput
        cfg.threads = threads
        cfg.max_faces = maxFaces
        cfg.track_enabled = 1
        // Full detector every three frames; KLT advances the 106-point mesh
        // between detector corrections for responsive preview tracking.
        cfg.detect_interval = 3
        cfg.analysis_max_dim = 720
        handle = wfd_create(&cfg)
        guard handle != nil else { throw SetupError.engineCreateFailed }
    }

    deinit {
        if let h = handle { wfd_destroy(h) }
    }

    /// Offer a frame; returns immediately. The engine keeps only the newest.
    func submit(_ buffer: CVPixelBuffer, sequence: Int) {
        lock.lock()
        latest = buffer
        latestSequence = sequence
        let shouldStart = !running
        running = true
        lock.unlock()
        if shouldStart { queue.async { [weak self] in self?.drain() } }
    }

    func currentFaces() -> [Face] {
        lock.lock(); defer { lock.unlock() }
        return faces
    }

    func resetTracking() {
        queue.async { [weak self] in
            guard let self, let handle = self.handle else { return }
            self.lock.lock()
            self.latest = nil
            self.latestSequence = 0
            self.faces = []
            self.lock.unlock()
            wfd_reset(handle)
        }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let buffer = latest else {
                running = false
                lock.unlock()
                return
            }
            latest = nil
            let sequence = latestSequence
            lock.unlock()
            process(buffer, sequence: sequence)
            lock.lock()
            if latest == nil {
                running = false
                lock.unlock()
                return
            }
            lock.unlock()
        }
    }

    private func process(_ buffer: CVPixelBuffer, sequence: Int) {
        guard let h = handle else { return }
        let started = CFAbsoluteTimeGetCurrent()
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)

        var raw = [wfd_face_t](repeating: wfd_face_t(), count: 3)
        let n = wfd_detect(h, base, WFD_PIXFMT_BGRA, Int32(width), Int32(height),
                           Int32(stride), 0, &raw, 3)
        var result: [Face] = []
        if n > 0 {
            for i in 0..<Int(n) {
                let f = raw[i]
                // Fixed C arrays import as tuples; reinterpret contiguously.
                var points: [wfd_point_t] = []
                withUnsafeBytes(of: f.landmarks) { rawBytes in
                    let buf = rawBytes.bindMemory(to: wfd_point_t.self)
                    for k in 0..<Int(f.num_landmarks) { points.append(buf[k]) }
                }
                var signals = [Float](repeating: 0, count: 4)
                points.withUnsafeBufferPointer {
                    _ = wfd_expression($0.baseAddress, Int32(points.count), &signals)
                }
                let l = f.kps
                let eyeMid = CGPoint(x: (CGFloat(l.0.x) + CGFloat(l.1.x)) / 2,
                                     y: (CGFloat(l.0.y) + CGFloat(l.1.y)) / 2)
                let mouthMid = CGPoint(x: (CGFloat(l.3.x) + CGFloat(l.4.x)) / 2,
                                       y: (CGFloat(l.3.y) + CGFloat(l.4.y)) / 2)
                result.append(Face(
                    id: f.track_id,
                    score: f.score,
                    rect: CGRect(x: CGFloat(f.rect.0), y: CGFloat(f.rect.1),
                                 width: CGFloat(f.rect.2 - f.rect.0),
                                 height: CGFloat(f.rect.3 - f.rect.1)),
                    eyeMid: eyeMid,
                    mouthMid: mouthMid,
                     landmarks: points.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) },
                    yaw: f.yaw, pitch: f.pitch, roll: f.roll,
                    gender: f.gender, age: f.age,
                    expression: (signals[0], signals[1], signals[2], signals[3])))
            }
        }
        lastMs = (CFAbsoluteTimeGetCurrent() - started) * 1000
        lock.lock()
        faces = result
        lock.unlock()
        onFaces?(result, sequence)
    }
}
