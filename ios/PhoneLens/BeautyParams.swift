import Foundation

struct BeautyParams: Equatable {
    var enabled = true
    var smooth: Float = 0.35
    var white: Float = 0.20
    var sharpen: Float = 0
    var pink: Float = 0
    // Preserve the original iOS fill-light control in addition to Android's four controls.
    var fill: Float = 0.12

    var uniforms: [Float] {
        [smooth, white, sharpen, pink, fill].map {
            enabled && $0.isFinite ? min(1, max(0, $0)) : 0
        }
    }
}
