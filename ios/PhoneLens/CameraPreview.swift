import MetalKit
import SwiftUI

struct CameraPreview: UIViewRepresentable {
    let renderer: BeautyRenderer
    let params: BeautyParams
    let running: Bool

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.delegate = renderer
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        renderer.params = params
        view.isPaused = !running
    }

    static func dismantleUIView(_ view: MTKView, coordinator: ()) {
        view.isPaused = true
        view.delegate = nil
    }
}
