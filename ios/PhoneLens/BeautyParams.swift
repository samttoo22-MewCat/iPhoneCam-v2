import Foundation

struct BeautyParams: Equatable {
    static let reshapeControls: [(name: String, slot: Int)] = [
        ("瘦臉", 0), ("小臉", 1), ("縮臉", 2), ("大眼", 3), ("小頭", 4),
        ("瘦鼻", 5), ("嘴型", 6), ("顴骨", 7), ("下巴", 8), ("瘦額", 9),
        ("眼距", 10), ("眼角", 11), ("鼻翼", 12), ("長鼻", 13), ("人中", 14),
        ("嘟嘟唇", 16), ("下頜線", 17), ("頭包臉", 18), ("鼻根", 19)
    ]

    static let reshapePresets: [(name: String, values: [Float])] = [
        ("自然", [0.10, 0.05, 0, 0.06, 0, 0.05, 0.02, 0.03, 0.02, 0,
                   0, 0.02, 0.04, 0, 0, 0, 0.03, 0.06, 0.02, 0.03]),
        ("清新", [0.18, 0.12, 0.04, 0.12, 0, 0.09, 0.04, 0.06, 0.04, 0.03,
                   0.02, 0.05, 0.07, 0, 0.02, 0, 0.05, 0.09, 0.04, 0.05]),
        ("上鏡", [0.28, 0.20, 0.08, 0.20, 0.03, 0.14, 0.08, 0.10, 0.08, 0.06,
                   0.04, 0.08, 0.11, 0.02, 0.04, 0, 0.08, 0.15, 0.08, 0.08]),
        ("明顯", [0.42, 0.33, 0.12, 0.30, 0.08, 0.22, 0.13, 0.16, 0.13, 0.10,
                   0.07, 0.12, 0.18, 0.04, 0.06, 0, 0.12, 0.22, 0.12, 0.12])
    ]
    var enabled = true
    var smooth: Float = 0.35
    var white: Float = 0.20
    var sharpen: Float = 0
    var pink: Float = 0
    // Preserve the original iOS fill-light control in addition to Android's four controls.
    var fill: Float = 0.12
    // Face-anchored mask (normalized uv of the camera buffer). faceValid == 0
    // is zero until SCRFD + 106-point tracking supplies a trusted face anchor.
    var faceValid: Float = 0
    var faceCX: Float = 0.5
    var faceCY: Float = 0.46
    var faceRX: Float = 0.40
    var faceRY: Float = 0.50
    /// 20 normalized 106-point mesh reshape controls. Kept separate from the
    /// fragment uniforms because the mesh is generated on the CPU per frame.
    var reshape = [Float](repeating: 0, count: 20)

    var reshapeActive: Bool { reshape.contains { $0.isFinite && $0 > 0.0001 } }

    var uniforms: [Float] {
        [smooth, white, sharpen, pink, fill,
         faceValid, faceCX, faceCY, faceRX, faceRY].map {
            enabled && $0.isFinite ? min(1, max(0, $0)) : 0
        }
    }
}
