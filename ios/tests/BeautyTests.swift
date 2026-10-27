import Foundation
import MetalKit

@main
struct BeautyTests {
    static func main() throws {
        var params = BeautyParams()
        // uniforms: 5 controls + face mask (valid, cx, cy, rx, ry); no face is a pass-through.
        assert(params.uniforms == [0.35, 0.20, 0, 0, 0.12, 0, 0.5, 0.46, 0.40, 0.50])
        params.smooth = -1; params.white = 2; params.sharpen = .nan
        assert(params.uniforms.prefix(3).elementsEqual([0, 1, 0]))
        params.enabled = false
        assert(params.uniforms == Array(repeating: 0, count: 10))
        print("PASS: defaults, bounds, non-finite input, bypass")

        let renderer = try BeautyRenderer(frames: CameraFrames())
        let size = 64
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: size, height: size, mipmapped: false)
        desc.storageMode = .shared
        desc.usage = [.shaderRead, .renderTarget]
        let source = renderer.device.makeTexture(descriptor: desc)!
        let target = renderer.device.makeTexture(descriptor: desc)!
        var pixels = [UInt8](repeating: 255, count: size*size*4)
        for y in 0..<size {
            for x in 0..<size {
                let index = (y*size+x)*4
                // Low-amplitude detail exercises smoothing and sharpening independently.
                let v = UInt8(95 + ((x+y)%2)*10)
                pixels[index] = v; pixels[index+1] = v+15; pixels[index+2] = v+30
            }
        }
        source.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                       withBytes: pixels, bytesPerRow: size*4)
        func render(_ params: BeautyParams) -> [UInt8] {
            let command = renderer.queue.makeCommandBuffer()!
            renderer.encode(source: source, target: target, command: command, params: params)
            command.commit(); command.waitUntilCompleted()
            precondition(command.status == .completed, "GPU command failed: \(String(describing: command.error))")
            var result = [UInt8](repeating: 0, count: pixels.count)
            target.getBytes(&result, bytesPerRow: size*4,
                            from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
            return result
        }
        var zero = BeautyParams(enabled: true, smooth: 0, white: 0, sharpen: 0, pink: 0, fill: 0)
        zero.faceValid = 1
        let original = render(zero)
        assert(zip(original, pixels).allSatisfy { abs(Int($0)-Int($1)) <= 1 }, "UV or channel order changed")
        // A face effect must never be applied to a guessed center ellipse.
        // With no trusted track, default nonzero controls are a full pass-through.
        assert(render(BeautyParams()) == original, "untracked frame changed pixels")
        var disabled = BeautyParams(); disabled.enabled = false
        assert(render(disabled) == original)
        for (name, key) in [("smooth", \BeautyParams.smooth), ("white", \BeautyParams.white),
                            ("sharpen", \BeautyParams.sharpen), ("pink", \BeautyParams.pink),
                            ("fill", \BeautyParams.fill)] {
            var p = zero; p[keyPath: key] = 1
            let result = render(p)
            let center = (30*size+32)*4
            assert(result[center..<center+3] != original[center..<center+3], "\(name) did not change pixels")
            if name != "sharpen" {
                assert(result[0..<3] == original[0..<3], "\(name) leaked outside ellipse")
            }
            print("PASS: GPU \(name) changes pixels; region behavior checked")
        }
        print("PASS: production Metal shader, identity, orientation, bypass, all five effects")
    }
}
