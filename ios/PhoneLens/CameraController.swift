import AVFoundation
import Combine

struct CameraLens: Identifiable {
    let id: String
    let name: String
}

final class CameraController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let frames = CameraFrames()
    @Published private(set) var isConfigured = false
    @Published private(set) var isRunning = false
    @Published private(set) var busy = false
    @Published private(set) var permissionDenied = false
    @Published private(set) var status = "正在準備相機…"
    @Published private(set) var lenses: [CameraLens] = []
    @Published private(set) var lensID = ""
    @Published private(set) var quality = 1080
    @Published private(set) var fps = 30
    @Published private(set) var dimensions = "—"
    @Published private(set) var aspect: CGFloat = 0.75
    @Published private(set) var measuredFPS = 0
    @Published var beauty = BeautyParams()
    @Published var comparing = false

    private let sessionQueue = DispatchQueue(label: "tw.phonecamera.phonelens.camera")
    private let frameQueue = DispatchQueue(label: "tw.phonecamera.phonelens.frames")
    private let output = AVCaptureVideoDataOutput()
    private var devices: [AVCaptureDevice] = []
    private var input: AVCaptureDeviceInput?
    private var wantsPreview = true
    private var active = true
    private var frameCount = 0
    private var lastTick = CFAbsoluteTimeGetCurrent()
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        observers.append(NotificationCenter.default.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] _ in
                self?.isRunning = false
                self?.status = "相機暫時被中斷，請回到 App 重試"
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { [weak self] _ in
                self?.setActive(true)
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] _ in
                self?.isRunning = false
                self?.status = "相機執行失敗，請暫停後重新開啟預覽"
            })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func prepare() {
        #if targetEnvironment(simulator)
        status = "模擬器沒有相機 · 可操作介面"
        return
        #else
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure(lens: "", quality: 1080, fps: 30)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                DispatchQueue.main.async { allowed ? self?.prepare() : self?.denied() }
            }
        default: denied()
        }
        #endif
    }

    private func denied() {
        permissionDenied = true
        status = "請在設定中允許相機權限"
    }

    func select(lens: String? = nil, quality: Int? = nil, fps: Int? = nil) {
        guard !busy, isConfigured else { return }
        configure(lens: lens ?? lensID, quality: quality ?? self.quality, fps: fps ?? self.fps)
    }

    private func configure(lens: String, quality: Int, fps: Int) {
        busy = true
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.devices.isEmpty {
                self.devices = AVCaptureDevice.DiscoverySession(
                    deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera],
                    mediaType: .video, position: .unspecified).devices
            }
            guard let device = self.devices.first(where: { $0.uniqueID == lens }) ??
                    self.devices.first(where: { $0.position == .front }) ?? self.devices.first else {
                self.fail("此裝置沒有可用相機")
                return
            }
            // Select a real 4:3 sensor format and display the actual dimensions.
            let candidates = device.formats.filter { format in
                let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return abs(Double(d.width)/Double(d.height)-4.0/3.0) < 0.02 &&
                    format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(fps) && $0.maxFrameRate >= Double(fps) }
            }
            guard let format = candidates.min(by: {
                abs(Int(CMVideoFormatDescriptionGetDimensions($0.formatDescription).height)-quality) <
                abs(Int(CMVideoFormatDescriptionGetDimensions($1.formatDescription).height)-quality)
            }) else {
                self.fail("此鏡頭不支援所選的 4:3／\(fps) FPS，原設定保持不變")
                return
            }
            do {
                let newInput = try AVCaptureDeviceInput(device: device)
                try device.lockForConfiguration()
                var deviceLocked = true
                defer { if deviceLocked { device.unlockForConfiguration() } }
                self.session.beginConfiguration()
                let oldInput = self.input
                if let oldInput { self.session.removeInput(oldInput) }
                guard self.session.canAddInput(newInput) else {
                    if let oldInput { self.session.addInput(oldInput) }
                    self.session.commitConfiguration()
                    self.fail("無法切換鏡頭，已保留原設定")
                    return
                }
                self.session.addInput(newInput)
                self.session.sessionPreset = .inputPriority
                device.activeFormat = format
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(fps))
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(fps))
                if self.session.outputs.isEmpty {
                    self.output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    self.output.alwaysDiscardsLateVideoFrames = true
                    self.output.setSampleBufferDelegate(self, queue: self.frameQueue)
                    guard self.session.canAddOutput(self.output) else {
                        self.session.removeInput(newInput)
                        if let oldInput { self.session.addInput(oldInput) }
                        self.session.commitConfiguration()
                        self.fail("無法建立相機影像輸出")
                        return
                    }
                    self.session.addOutput(self.output)
                }
                if let connection = self.output.connection(with: .video) {
                    if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                    if connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false
                        connection.isVideoMirrored = device.position == .front
                    }
                }
                self.session.commitConfiguration()
                device.unlockForConfiguration()
                deviceLocked = false
                self.input = newInput
                self.frames.put(nil)
                let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let available = self.devices.map { CameraLens(id: $0.uniqueID, name: Self.label($0)) }
                if self.wantsPreview && self.active { self.session.startRunning() }
                let running = self.session.isRunning
                DispatchQueue.main.async {
                    self.lenses = available
                    self.lensID = device.uniqueID
                    self.quality = quality
                    self.fps = fps
                    self.dimensions = "\(d.height) × \(d.width)"
                    self.aspect = CGFloat(d.height)/CGFloat(d.width)
                    self.isConfigured = true
                    self.isRunning = running
                    self.permissionDenied = false
                    self.busy = false
                    self.status = running ? "手機預覽 · 不傳送到電腦" : "預覽已暫停"
                }
            } catch { self.fail("相機設定失敗：\(error.localizedDescription)") }
        }
    }

    private static func label(_ device: AVCaptureDevice) -> String {
        if device.position == .front { return "前置鏡頭" }
        switch device.deviceType {
        case .builtInUltraWideCamera: return "後置超廣角"
        case .builtInTelephotoCamera: return "後置望遠"
        default: return "後置主鏡頭"
        }
    }

    func togglePreview() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.wantsPreview.toggle()
            self.updateRunning()
        }
    }

    func setActive(_ active: Bool) {
        sessionQueue.async { [weak self] in
            self?.active = active
            self?.updateRunning()
        }
    }

    private func updateRunning() {
        if wantsPreview && active && input != nil { session.startRunning() }
        else { session.stopRunning(); frames.put(nil) }
        let running = session.isRunning
        DispatchQueue.main.async {
            self.isRunning = running
            self.measuredFPS = 0
            if self.isConfigured { self.status = running ? "手機預覽 · 不傳送到電腦" : "預覽已暫停" }
        }
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async { self.status = message; self.busy = false }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frames.put(buffer)
        frameCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        if now-lastTick >= 1 {
            let rate = Int((Double(frameCount)/(now-lastTick)).rounded())
            frameCount = 0
            lastTick = now
            DispatchQueue.main.async { self.measuredFPS = rate }
        }
    }
}
