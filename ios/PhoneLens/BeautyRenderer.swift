import MetalKit
import CoreVideo

// One latest-frame slot: slow rendering drops old frames instead of growing a queue.
// Each camera buffer carries a monotonic sequence so face results can be checked
// against the frame currently being displayed.
final class CameraFrames {
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var seq = 0

    @discardableResult
    func put(_ frame: CVPixelBuffer?) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if let frame { seq += 1; latest = frame; return seq }
        latest = nil
        return seq
    }

    func get() -> (buffer: CVPixelBuffer, sequence: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard let latest else { return nil }
        return (latest, seq)
    }
}

/// Normalized face anchor shared with the shader and the debug overlay.
struct FaceAnchor {
    var valid: Float
    var cx: Float
    var cy: Float
    var rx: Float
    var ry: Float
    /// Camera buffer sequence the result was computed from.
    var sequence: Int
}

/// Face mask state shared between the detect queue and the render loop.
/// When a face is tracked the beauty ellipse anchors to it; when the lock is
/// lost the weight decays to zero. Never apply a face effect to an assumed
/// screen-center face: the actual subject may be anywhere in the frame.
///
/// Freshness rule: analysis results carry the camera sequence they were
/// computed from. If the frame being displayed is more than `freshTolerance`
/// sequences ahead, the result is stale and must not paint a moved face.
final class FaceState {
    static let freshTolerance = 3

    private let lock = NSLock()
    private var cx: Float = 0.5
    private var cy: Float = 0.46
    private var rx: Float = 0.40
    private var ry: Float = 0.50
    private var valid: Float = 0
    private var seq = 0
    private var meshSeq = 0
    private var landmarks: [SIMD2<Float>] = []

    /// uv-space anchor of the tracked face (all values in 0...1).
    func update(valid: Float, cx: Float, cy: Float, rx: Float, ry: Float, sequence: Int) {
        lock.lock()
        defer { lock.unlock() }
        self.cx = min(1, max(0, cx))
        self.cy = min(1, max(0, cy))
        self.rx = min(0.9, max(0.05, rx))
        self.ry = min(0.9, max(0.05, ry))
        self.valid = min(1, max(0, valid))
        self.seq = sequence
    }

    /// No face this frame: fade the face effect out instead of guessing a
    /// fixed screen-center position.
    func updateLost() {
        lock.lock()
        defer { lock.unlock() }
        valid = max(0, valid - 0.34)
        if valid == 0 { landmarks.removeAll(keepingCapacity: true) }
    }

    /// Store normalized 106-point coordinates; the renderer converts them to
    /// the current camera texture size immediately before mesh generation.
    func updateMesh(_ points: [CGPoint], width: Int, height: Int, sequence: Int) {
        guard points.count >= 106, width > 0, height > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        landmarks = points.prefix(106).map {
            SIMD2<Float>(min(1, max(0, Float($0.x) / Float(width))),
                         min(1, max(0, Float($0.y) / Float(height))))
        }
        meshSeq = sequence
    }

    /// Read for the render loop. A stale result (displayed frame far ahead of
    /// the analyzed frame) is treated as no-face so the effect never lags
    /// visibly behind a fast-moving subject.
    func apply(to params: inout BeautyParams, frameSequence: Int) {
        lock.lock()
        defer { lock.unlock() }
        if frameSequence - seq > Self.freshTolerance {
            params.faceValid = 0
            return
        }
        params.faceValid = valid
        params.faceCX = cx
        params.faceCY = cy
        params.faceRX = rx
        params.faceRY = ry
    }

    #if os(iOS) && !targetEnvironment(simulator)
    func meshTriangles(controls: [Float], width: Int, height: Int, frameSequence: Int) -> [Float] {
        guard controls.contains(where: { $0.isFinite && $0 > 0.0001 }),
              width > 1, height > 1 else { return [] }
        lock.lock()
        let points = landmarks
        let isValid = valid > 0.5 && frameSequence - meshSeq <= Self.freshTolerance
        lock.unlock()
        guard isValid, points.count == 106 else { return [] }
        var input = points.map { wfd_point_t(x: $0.x * Float(width), y: $0.y * Float(height)) }
        var safeControls = Array(controls.prefix(20))
        if safeControls.count < 20 { safeControls += repeatElement(0, count: 20 - safeControls.count) }
        var triangles = [Float](repeating: 0, count: 400 * 12)
        let count = input.withUnsafeBufferPointer { pointBuffer in
            safeControls.withUnsafeBufferPointer { controlBuffer in
                wfd_warp106(pointBuffer.baseAddress, Int32(input.count), controlBuffer.baseAddress,
                            Int32(safeControls.count), Float(width), Float(height),
                            &triangles, 400)
            }
        }
        guard count > 0 else { return [] }
        return Array(triangles.prefix(Int(count) * 12))
    }
    #endif
}

final class BeautyRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let meshPipeline: MTLRenderPipelineState
    private var cache: CVMetalTextureCache?
    private let inFlight = DispatchSemaphore(value: 1)
    /// Preview and encoder have independent output lifecycles. The stream path
    /// must never wait for MTKView.currentDrawable (a sheet can hide it).
    private let streamInFlight = DispatchSemaphore(value: 1)
    let frames: CameraFrames
    let faceState = FaceState()
    var params = BeautyParams()
    /// Beauty-processed frame ready for the stream encoder (buffer, sequence).
    /// Called on the GPU completion thread; heavy work must be dispatched.
    /// Unused on simulator (no stream target, no camera).
    var streamFrameSink: ((CVPixelBuffer, Int) -> Void)?
    #if os(iOS) && !targetEnvironment(simulator)
    private var streamPixelBuffer: CVPixelBuffer?
    private var streamCVTexture: CVMetalTexture?
    #endif

    init(frames: CameraFrames) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw NSError(domain: "PhoneLens.Metal", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "此裝置無法啟用 Metal 美顏"])
        }
        self.device = device
        self.queue = queue
        self.frames = frames
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "beautyVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "beautyFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.vertexFunction = library.makeFunction(name: "meshVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "meshFragment")
        meshPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        super.init()
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess else {
            throw NSError(domain: "PhoneLens.Metal", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "無法建立相機 GPU 紋理快取"])
        }
    }

    // Shared by on-device preview and the offscreen GPU regression tests.
    func encode(source: MTLTexture, target: MTLTexture, command: MTLCommandBuffer,
                params: BeautyParams) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        var values = params.uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentBytes(&values, length: MemoryLayout<Float>.stride * values.count, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    func draw(in view: MTKView) {
        guard inFlight.wait(timeout: .now()) == .success else { return }
        guard let (frame, frameSeq) = frames.get(), let cache,
              let drawable = view.currentDrawable, let command = queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, frame, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(frame), CVPixelBufferGetHeight(frame), 0, &cvTexture)
        guard result == kCVReturnSuccess, let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            inFlight.signal()
            return
        }
        var effective = params
        faceState.apply(to: &effective, frameSequence: frameSeq)
        #if os(iOS) && !targetEnvironment(simulator)
        let triangles = faceState.meshTriangles(controls: effective.reshape,
                                                 width: texture.width, height: texture.height,
                                                 frameSequence: frameSeq)
        if !triangles.isEmpty, let intermediate = makeIntermediate(width: texture.width,
                                                                     height: texture.height) {
            // Preserve the processed image, then overwrite only destination mesh triangles.
            encode(source: texture, target: intermediate, command: command, params: effective)
            encode(source: intermediate, target: drawable.texture, command: command,
                   params: BeautyParams(enabled: false))
            encodeMesh(source: intermediate, target: drawable.texture,
                       command: command, triangles: triangles)
        } else {
            encode(source: texture, target: drawable.texture, command: command, params: effective)
        }
        #else
        encode(source: texture, target: drawable.texture, command: command, params: effective)
        #endif
        command.present(drawable)
        let semaphore = inFlight
        command.addCompletedHandler { _ in
            // Core Video's backing buffer must survive until the GPU finishes reading it.
            withExtendedLifetime((frame, cvTexture)) {
                semaphore.signal()
            }
        }
        command.commit()
    }

    /// Camera callback entry point for streaming. Unlike draw(in:), this owns
    /// no MTKView drawable, so modal sheets or a temporarily occluded preview
    /// cannot stop the encoder. It uses the same shader and face state as the
    /// preview path and only keeps one pending GPU frame for low latency.
    func renderForStream(_ frame: CVPixelBuffer, sequence: Int) {
        #if os(iOS) && !targetEnvironment(simulator)
        guard streamInFlight.wait(timeout: .now()) == .success,
              let cache, let command = queue.makeCommandBuffer() else { return }
        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, frame, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(frame), CVPixelBufferGetHeight(frame), 0, &cvTexture)
        guard result == kCVReturnSuccess, let cvTexture,
              let source = CVMetalTextureGetTexture(cvTexture),
              let target = makeStreamTarget(width: source.width, height: source.height) else {
            streamInFlight.signal()
            return
        }
        var effective = params
        faceState.apply(to: &effective, frameSequence: sequence)
        let triangles = faceState.meshTriangles(controls: effective.reshape,
                                                 width: source.width, height: source.height,
                                                 frameSequence: sequence)
        if !triangles.isEmpty, let intermediate = makeIntermediate(width: source.width, height: source.height) {
            encode(source: source, target: intermediate, command: command, params: effective)
            encode(source: intermediate, target: target.texture, command: command,
                   params: BeautyParams(enabled: false))
            encodeMesh(source: intermediate, target: target.texture, command: command, triangles: triangles)
        } else {
            encode(source: source, target: target.texture, command: command, params: effective)
        }
        let semaphore = streamInFlight
        let sink = streamFrameSink
        command.addCompletedHandler { _ in
            withExtendedLifetime((frame, cvTexture, target.buffer)) {
                if let sink { sink(target.buffer, sequence) }
                semaphore.signal()
            }
        }
        command.commit()
        #endif
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private func makeIntermediate(width: Int, height: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                         width: width, height: height,
                                                         mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    #if os(iOS) && !targetEnvironment(simulator)
    /// IOSurface-backed BGRA pixel buffer wrapped as a renderable Metal
    /// texture; the same surface is handed to the H.264 encoder.
    private func makeStreamTarget(width: Int, height: Int) -> (buffer: CVPixelBuffer, texture: MTLTexture)? {
        if let streamPixelBuffer,
           CVPixelBufferGetWidth(streamPixelBuffer) == width,
           CVPixelBufferGetHeight(streamPixelBuffer) == height,
           let streamCVTexture, let texture = CVMetalTextureGetTexture(streamCVTexture) {
            return (streamPixelBuffer, texture)
        }
        var pixelBuffer: CVPixelBuffer?
        let iosurface = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true
        ] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                  iosurface, &pixelBuffer) == kCVReturnSuccess, let pixelBuffer else {
            return nil
        }
        let usage = MTLTextureUsage.renderTarget.union(.shaderRead)
        let attributes = [kCVMetalTextureUsage: usage.rawValue] as CFDictionary
        var cvTexture: CVMetalTexture?
        guard let textureCache = cache,
              CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixelBuffer, attributes,
                                                        .bgra8Unorm, width, height, 0,
                                                        &cvTexture) == kCVReturnSuccess,
              let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else {
            return nil
        }
        streamPixelBuffer = pixelBuffer
        streamCVTexture = cvTexture
        return (pixelBuffer, texture)
    }
    #endif

    private func encodeMesh(source: MTLTexture, target: MTLTexture, command: MTLCommandBuffer,
                            triangles: [Float]) {
        struct MeshVertex { var position: SIMD2<Float>; var uv: SIMD2<Float> }
        var vertices: [MeshVertex] = []
        vertices.reserveCapacity(triangles.count / 4)
        for i in stride(from: 0, to: triangles.count, by: 12) {
            for v in 0..<3 {
                let sourceUV = SIMD2<Float>(triangles[i + v * 2], triangles[i + v * 2 + 1])
                let destinationUV = SIMD2<Float>(triangles[i + 6 + v * 2], triangles[i + 6 + v * 2 + 1])
                vertices.append(MeshVertex(position: SIMD2(destinationUV.x * 2 - 1, 1 - destinationUV.y * 2),
                                           uv: sourceUV))
            }
        }
        guard let buffer = device.makeBuffer(bytes: vertices,
                                             length: MemoryLayout<MeshVertex>.stride * vertices.count,
                                             options: .storageModeShared) else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(meshPipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
    }

    // Port of Android BeautyShaders.FINAL_OES_FRAG at upstream 17c3e1a.
    // Effects are strictly gated by tracked-face confidence; UVs refer to the
    // camera buffer consumed by both Metal and FaceEngine.
    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct VertexOut { float4 position [[position]]; float2 uv; };
    vertex VertexOut beautyVertex(uint id [[vertex_id]]) {
        const float2 p[] = {float2(-1,1),float2(-1,-1),float2(1,1),float2(1,-1)};
        const float2 uv[] = {float2(0,0),float2(0,1),float2(1,0),float2(1,1)};
        return {float4(p[id],0,1), uv[id]};
    }
    struct MeshOut { float4 position [[position]]; float2 uv; };
    struct MeshVertexIn { float2 position; float2 uv; };
    vertex MeshOut meshVertex(const device MeshVertexIn *vertices [[buffer(0)]], uint id [[vertex_id]]) {
        return {float4(vertices[id].position, 0, 1), vertices[id].uv};
    }
    fragment float4 meshFragment(MeshOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        return tex.sample(s, in.uv);
    }
    fragment float4 beautyFragment(VertexOut in [[stage_in]],
        texture2d<float> tex [[texture(0)]], constant float *b [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 uv = in.uv;
        float3 src = tex.sample(s,uv).rgb;
        if (b[0]+b[1]+b[2]+b[3]+b[4] < 0.00001) return float4(src,1);
        float tracked = clamp(b[5], 0.0, 1.0);
        if (tracked < 0.0001) return float4(src,1);
        float2 d = (uv-float2(b[6],b[7]))/max(float2(b[8],b[9]),float2(0.05,0.05));
        float f = (1.0-smoothstep(0.55,1.0,dot(d,d))) * tracked;
        float2 t = 1.0/float2(tex.get_width(),tex.get_height());
        float2 w = t*2.5;
        float3 bl = src*0.28;
        bl += tex.sample(s,uv+float2(w.x,0)).rgb*0.18;
        bl += tex.sample(s,uv-float2(w.x,0)).rgb*0.18;
        bl += tex.sample(s,uv+float2(0,w.y)).rgb*0.18;
        bl += tex.sample(s,uv-float2(0,w.y)).rgb*0.18;
        float keep = smoothstep(0.020,0.090,length(src-bl));
        float3 c = mix(src,bl,clamp(b[0]*f*(1.0-keep*0.85),0.0,1.0));
        float3 n = (tex.sample(s,uv+float2(t.x,0)).rgb+
                    tex.sample(s,uv-float2(t.x,0)).rgb+
                    tex.sample(s,uv+float2(0,t.y)).rgb+
                    tex.sample(s,uv-float2(0,t.y)).rgb)*0.25;
        c = clamp(c+(c-n)*b[2]*mix(1.0,0.35,f),0.0,1.0);
        float y = dot(c,float3(0.299,0.587,0.114));
        float y2 = mix(y,smoothstep(0.0,1.0,y)*0.90+0.10,b[1]*f*0.85);
        y2 = mix(y2,pow(clamp(y2,0.0,1.0),0.82),b[1]*f*0.5);
        c = clamp(c*(y>0.001 ? y2/y : 1.0),0.0,1.0);
        c = mix(c,c*float3(1.0,0.965,0.955),b[3]*f);
        c = clamp(c+float3(0.030,0.008,0.014)*b[3]*f*(1.0-y),0.0,1.0);
        c = mix(c,1.0-(1.0-c)*exp2(-0.6*b[4]),f);
        return float4(c,1);
    }
    """
}
