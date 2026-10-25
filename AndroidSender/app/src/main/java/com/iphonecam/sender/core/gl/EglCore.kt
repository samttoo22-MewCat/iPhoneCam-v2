package com.iphonecam.sender.core.gl

import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.view.Surface

class EglCore {
    private companion object {
        const val EGL_RECORDABLE_ANDROID = 0x3142
    }

    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var context: EGLContext = EGL14.EGL_NO_CONTEXT
    private var config: EGLConfig? = null

    init {
        display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        check(display != EGL14.EGL_NO_DISPLAY) { "eglGetDisplay failed" }
        val ver = IntArray(2)
        check(EGL14.eglInitialize(display, ver, 0, ver, 1)) { "eglInitialize failed" }
        val base = intArrayOf(
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT or EGL14.EGL_PBUFFER_BIT
        )
        val cfg = arrayOfNulls<EGLConfig>(1)
        val n = IntArray(1)
        var ok = false
        run {
            val attrs = base + intArrayOf(EGL_RECORDABLE_ANDROID, 1, EGL14.EGL_NONE)
            ok = EGL14.eglChooseConfig(display, attrs, 0, cfg, 0, 1, n, 0) && n[0] > 0
        }
        if (!ok) {
            val attrs = base + intArrayOf(EGL14.EGL_NONE)
            ok = EGL14.eglChooseConfig(display, attrs, 0, cfg, 0, 1, n, 0) && n[0] > 0
        }
        check(ok) { "eglChooseConfig failed" }
        config = cfg[0]
        val visual = IntArray(1)
        EGL14.eglGetConfigAttrib(display, config, EGL14.EGL_NATIVE_VISUAL_ID, visual, 0)
        android.util.Log.d("BeautyGL", "egl config visualId=${visual[0]}")
        context = EGL14.eglCreateContext(
            display, config, EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0
        )
        check(context != EGL14.EGL_NO_CONTEXT) { "eglCreateContext failed" }
    }

    fun createWindowSurface(surface: Surface): EGLSurface? {
        val c = config ?: return null
        val s = EGL14.eglCreateWindowSurface(
            display, c, surface, intArrayOf(EGL14.EGL_NONE), 0
        )
        if (s == EGL14.EGL_NO_SURFACE) {
            val err = EGL14.eglGetError()
            android.util.Log.e(
                "BeautyGL",
                "eglCreateWindowSurface failed err=0x${Integer.toHexString(err)} valid=${surface.isValid}"
            )
            probeConfigs(surface)
            return null
        }
        return s
    }

    private fun probeConfigs(surface: Surface) {
        val attrs = intArrayOf(
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT or EGL14.EGL_PBUFFER_BIT,
            EGL14.EGL_NONE
        )
        val cfgs = arrayOfNulls<EGLConfig>(32)
        val n = IntArray(1)
        if (!EGL14.eglChooseConfig(display, attrs, 0, cfgs, 0, 32, n, 0)) {
            android.util.Log.e("BeautyGL", "probe: eglChooseConfig failed")
            return
        }
        android.util.Log.d("BeautyGL", "probe configs=${n[0]}")
        for (i in 0 until n[0]) {
            val s = EGL14.eglCreateWindowSurface(
                display, cfgs[i], surface, intArrayOf(EGL14.EGL_NONE), 0
            )
            if (s != EGL14.EGL_NO_SURFACE) {
                val v = IntArray(1)
                EGL14.eglGetConfigAttrib(display, cfgs[i], EGL14.EGL_NATIVE_VISUAL_ID, v, 0)
                android.util.Log.d("BeautyGL", "probe[$i] OK visualId=${v[0]}")
                EGL14.eglDestroySurface(display, s)
            } else {
                android.util.Log.d(
                    "BeautyGL", "probe[$i] err=0x${Integer.toHexString(EGL14.eglGetError())}"
                )
            }
        }
    }

    fun makeCurrent(surface: EGLSurface): Boolean =
        EGL14.eglMakeCurrent(display, surface, surface, context)

    fun createPbufferSurface(w: Int = 1, h: Int = 1): EGLSurface? {
        val c = config ?: return null
        val attrs = intArrayOf(
            EGL14.EGL_WIDTH, w,
            EGL14.EGL_HEIGHT, h,
            EGL14.EGL_NONE
        )
        val s = EGL14.eglCreatePbufferSurface(display, c, attrs, 0)
        return if (s == EGL14.EGL_NO_SURFACE) null else s
    }

    fun swapBuffers(surface: EGLSurface): Boolean {
        val ok = EGL14.eglSwapBuffers(display, surface)
        if (!ok) {
            android.util.Log.e(
                "BeautyGL", "eglSwapBuffers err=0x${Integer.toHexString(EGL14.eglGetError())}"
            )
        }
        return ok
    }

    fun setPresentationTime(surface: EGLSurface, ns: Long) =
        EGLExt.setPresentationTime(display, surface, ns)

    fun releaseSurface(surface: EGLSurface?) {
        if (surface != null && surface != EGL14.EGL_NO_SURFACE) {
            EGL14.eglDestroySurface(display, surface)
        }
    }

    fun release() {
        if (display != EGL14.EGL_NO_DISPLAY) {
            EGL14.eglMakeCurrent(
                display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT
            )
            if (context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context)
            EGL14.eglTerminate(display)
        }
        display = EGL14.EGL_NO_DISPLAY
        context = EGL14.EGL_NO_CONTEXT
        config = null
    }

    private object EGLExt {
        private val hasPresentationTime = try {
            EGL14::class.java.getMethod(
                "eglPresentationTimeANDROID",
                EGLDisplay::class.java, EGLSurface::class.java, Long::class.javaPrimitiveType
            )
            true
        } catch (_: Throwable) {
            false
        }

        fun setPresentationTime(display: EGLDisplay, surface: EGLSurface, ns: Long) {
            if (!hasPresentationTime) return
            try {
                EGL14::class.java.getMethod(
                    "eglPresentationTimeANDROID",
                    EGLDisplay::class.java, EGLSurface::class.java, Long::class.javaPrimitiveType
                ).invoke(null, display, surface, ns)
            } catch (_: Throwable) {
            }
        }
    }
}