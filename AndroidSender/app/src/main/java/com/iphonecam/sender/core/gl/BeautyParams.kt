package com.iphonecam.sender.core.gl

import org.json.JSONObject

data class BeautyParams(
    val enabled: Boolean = false,
    val smooth: Float = 0f,
    val white: Float = 0f,
    val sharpen: Float = 0f,
    val pink: Float = 0f,
    val contour: Float = 0f,
    val faceCx: Float = 0.5f,
    val faceCy: Float = 0.46f,
    val faceRx: Float = 0.40f,
    val faceRy: Float = 0.50f,
) {
    val hasEffect: Boolean
        get() = enabled &&
            (smooth > 0.001f || white > 0.001f || sharpen > 0.001f || pink > 0.001f)

    fun normalized(): BeautyParams = copy(
        smooth = smooth.coerceIn(0f, 1f),
        white = white.coerceIn(0f, 1f),
        sharpen = sharpen.coerceIn(0f, 1f),
        pink = pink.coerceIn(0f, 1f),
        contour = contour.coerceIn(0f, 1f),
    )

    companion object {
        fun fromJson(o: JSONObject): BeautyParams = BeautyParams(
            enabled = o.optBoolean("enabled", true),
            smooth = f(o, "smooth", "blur_skin", "mopi"),
            white = f(o, "white", "whiten", "meibai"),
            sharpen = f(o, "sharpen", "sharp", "qingxi"),
            pink = f(o, "pink", "rosy", "hongrun"),
            contour = f(o, "contour", "thin_face", "shoulian"),
        ).normalized()

        private fun f(o: JSONObject, vararg keys: String): Float {
            for (k in keys) {
                if (o.has(k)) return o.optDouble(k, 0.0).toFloat()
            }
            return 0f
        }
    }
}
