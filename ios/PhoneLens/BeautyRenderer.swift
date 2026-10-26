import MetalKit
import CoreVideo

// One latest-frame slot: slow rendering drops old frames instead of growing a queue.
final class CameraFrames {
    private let lock = NSLock()
    private var latest: CVPixelBuffer?

    func put(_ frame: CVPixelBuffer?) {
        lock.lock()
        latest = frame
        lock.unlock()
    }

    func get() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }
}

final class BeautyRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var cache: CVMetalTextureCache?
    private let inFlight = DispatchSemaphore(value: 1)
    let frames: CameraFrames
    var params = BeautyParams()

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
        guard let frame = frames.get(), let cache,
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
        encode(source: texture, target: drawable.texture, command: command, params: params)
        command.present(drawable)
        let semaphore = inFlight
        command.addCompletedHandler { _ in
            // Core Video's backing buffer must survive until the GPU finishes reading it.
            withExtendedLifetime((frame, cvTexture)) { _ = semaphore.signal() }
        }
        command.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    // Port of Android BeautyShaders.FINAL_OES_FRAG at upstream 17c3e1a.
    // Fixed central ellipse, not face detection. UVs refer to the rotated portrait buffer.
    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct VertexOut { float4 position [[position]]; float2 uv; };
    vertex VertexOut beautyVertex(uint id [[vertex_id]]) {
        const float2 p[] = {float2(-1,1),float2(-1,-1),float2(1,1),float2(1,-1)};
        const float2 uv[] = {float2(0,0),float2(0,1),float2(1,0),float2(1,1)};
        return {float4(p[id],0,1), uv[id]};
    }
    fragment float4 beautyFragment(VertexOut in [[stage_in]],
        texture2d<float> tex [[texture(0)]], constant float *b [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 uv = in.uv;
        float3 src = tex.sample(s,uv).rgb;
        if (b[0]+b[1]+b[2]+b[3]+b[4] < 0.00001) return float4(src,1);
        float2 d = (uv-float2(0.5,0.46))/float2(0.40,0.50);
        float f = 1.0-smoothstep(0.55,1.0,dot(d,d));
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
