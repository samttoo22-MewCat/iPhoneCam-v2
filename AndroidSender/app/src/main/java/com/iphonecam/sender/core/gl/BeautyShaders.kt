package com.iphonecam.sender.core.gl

internal object BeautyShaders {

    const val OES_UV_VERT = """
attribute vec4 aPos;
attribute vec2 aTex;
uniform vec2 uScale;
uniform float uRot;
uniform float uFlipY;
varying vec2 vTex;
void main() {
    vec2 t = aTex;
    if (uFlipY > 0.5) t.y = 1.0 - t.y;
    if (uRot > 45.0 && uRot < 135.0) {
        t = vec2(1.0 - t.y, t.x);
    } else if (uRot > 135.0 && uRot < 225.0) {
        t = vec2(1.0 - t.x, 1.0 - t.y);
    } else if (uRot > 225.0) {
        t = vec2(t.y, 1.0 - t.x);
    }
    vTex = t;
    gl_Position = vec4(aPos.xy * uScale, aPos.z, 1.0);
}
"""

    const val OES_FRAG = """
#extension GL_OES_EGL_image_external : require
precision mediump float;
varying vec2 vTex;
uniform samplerExternalOES uTex;
void main() {
    gl_FragColor = texture2D(uTex, vTex);
}
"""

    const val FINAL_OES_FRAG = """
#extension GL_OES_EGL_image_external : require
precision mediump float;
varying vec2 vTex;

uniform samplerExternalOES uTex;
uniform vec2 uTexel;

uniform float uSmooth;
uniform float uSharpen;
uniform float uWhite;
uniform float uPink;
uniform vec4 uFace;

const vec3 LUMA = vec3(0.299, 0.587, 0.114);

float faceMask(vec2 uv) {
    vec2 d = (uv - uFace.xy) / uFace.zw;
    return 1.0 - smoothstep(0.55, 1.0, dot(d, d));
}

void main() {
    vec2 uv = vTex;
    float f = faceMask(uv);
    vec3 src = texture2D(uTex, uv).rgb;

    vec2 w = uTexel * 2.5;
    vec3 bl = src * 0.28;
    bl += texture2D(uTex, uv + vec2(w.x, 0.0)).rgb * 0.18;
    bl += texture2D(uTex, uv - vec2(w.x, 0.0)).rgb * 0.18;
    bl += texture2D(uTex, uv + vec2(0.0, w.y)).rgb * 0.18;
    bl += texture2D(uTex, uv - vec2(0.0, w.y)).rgb * 0.18;

    float detail = length(src - bl);
    float keep = smoothstep(0.020, 0.090, detail);
    float smoothMix = clamp(uSmooth * f * (1.0 - keep * 0.85), 0.0, 1.0);
    vec3 c = mix(src, bl, smoothMix);

    vec3 n = (texture2D(uTex, uv + vec2(uTexel.x, 0.0)).rgb +
              texture2D(uTex, uv - vec2(uTexel.x, 0.0)).rgb +
              texture2D(uTex, uv + vec2(0.0, uTexel.y)).rgb +
              texture2D(uTex, uv - vec2(0.0, uTexel.y)).rgb) * 0.25;
    c = clamp(c + (c - n) * uSharpen * mix(1.0, 0.35, f), 0.0, 1.0);

    float y = dot(c, LUMA);
    float y2 = mix(y, smoothstep(0.0, 1.0, y) * 0.90 + 0.10, uWhite * f * 0.85);
    y2 = mix(y2, pow(clamp(y2, 0.0, 1.0), 0.82), uWhite * f * 0.5);
    float gain = y > 0.001 ? (y2 / y) : 1.0;
    c = clamp(c * gain, 0.0, 1.0);

    vec3 warm = vec3(1.0, 0.965, 0.955);
    c = mix(c, c * warm, uPink * f);
    c = clamp(c + vec3(0.030, 0.008, 0.014) * uPink * f * (1.0 - y), 0.0, 1.0);

    gl_FragColor = vec4(c, 1.0);
}
"""
}
