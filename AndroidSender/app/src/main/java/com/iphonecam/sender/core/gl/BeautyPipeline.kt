package com.iphonecam.sender.core.gl

import android.graphics.SurfaceTexture
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class BeautyPipeline(private val log: (String) -> Unit) {

    @Volatile
    var params: BeautyParams = BeautyParams()

    private val thread = HandlerThread("beauty-gl").apply { start() }
    private val handler = Handler(thread.looper)
    private val pending = AtomicBoolean(false)
    private val again = AtomicBoolean(false)

    private var egl: EglCore? = null
    private var dummyEgl: EGLSurface? = null
    private var oesTex = 0
    private var oesSt: SurfaceTexture? = null
    private var cameraSurface: Surface? = null

    private var previewSurface: Surface? = null
    private var previewEgl: EGLSurface? = null
    private var viewW = 0
    private var viewH = 0
    @Volatile private var previewRot = 90

    private var encoderSurface: Surface? = null
    private var encoderEgl: EGLSurface? = null

    private var progOes = 0
    private var progFinal = 0

    private var frameW = 0
    private var frameH = 0

    private val texMatrix = FloatArray(16)
    private var frameLogged = false



@Volatile private var released = false
    private var matrixLogged = false

    fun start(width: Int, height: Int): Surface? {
        var result: Surface? = null
        val latch = CountDownLatch(1)
        handler.post {
            try {
                initGl(width, height)
                result = cameraSurface
            } catch (e: Exception) {
                log("美顏 GL 初始化失敗：${e.message}")
                android.util.Log.e("BeautyGL", "initGl", e)
            } finally {
                latch.countDown()
            }
        }
        latch.await(3, TimeUnit.SECONDS)
        return result
    }

    fun cameraInput(): Surface? = cameraSurface

    fun setPreviewRotation(deg: Int) {
        previewRot = ((deg % 360) + 360) % 360
    }

    fun setPreview(surface: Surface?, w: Int = 0, h: Int = 0) {
        handler.post {
            releasePreview()
            if (surface == null) return@post
            viewW = w
            viewH = h
            try {
                previewSurface = surface
                previewEgl = egl?.createWindowSurface(surface)
                android.util.Log.d("BeautyGL", "preview egl=${previewEgl != null} view=${w}x$h")
                if (previewEgl == null) log("美顏預覽 EGL surface 建立失敗")
                requestRender()
            } catch (e: Exception) {
                log("美顏預覽輸出失敗：${e.message}")
                android.util.Log.e("BeautyGL", "setPreview", e)
            }
        }
    }

    fun setEncoder(surface: Surface?, sync: Boolean = false) {
        val job = Runnable {
            releaseEncoder()
            encoderSurface = surface
            if (surface != null) {
                encoderEgl = egl?.createWindowSurface(surface)
                android.util.Log.d("BeautyGL", "encoder egl=${encoderEgl != null}")
            }
        }
        if (!sync) {
            handler.post(job)
            return
        }
        val latch = CountDownLatch(1)
        handler.post {
            try {
                job.run()
            } finally {
                latch.countDown()
            }
        }
        try {
            latch.await(600, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
        }
    }

    fun requestRender() {
        if (released) return
        if (!frameLogged) {
            frameLogged = true
            android.util.Log.d("BeautyGL", "first frame available")
        }
        if (!pending.compareAndSet(false, true)) {
            again.set(true)
            return
        }
        handler.post { renderFrame() }
    }

    private fun initGl(width: Int, height: Int) {
        val core = EglCore()
        egl = core
        val pb = core.createPbufferSurface(1, 1)
        if (pb != null) {
            core.makeCurrent(pb)
            dummyEgl = pb
        } else {
            val tmp = SurfaceTexture(0)
            val surf = Surface(tmp)
            val s = core.createWindowSurface(surf)
            if (s == null) {
                tmp.release(); surf.release()
                throw IllegalStateException("no EGL surface")
            }
            core.makeCurrent(s)
            core.releaseSurface(s)
            surf.release()
            tmp.release()
        }
        progOes = GlProgram.build(BeautyShaders.OES_UV_VERT, BeautyShaders.OES_FRAG)
        progFinal = GlProgram.build(BeautyShaders.OES_UV_VERT, BeautyShaders.FINAL_OES_FRAG)
        
        val t = IntArray(1)
        GLES20.glGenTextures(1, t, 0)
        oesTex = t[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTex)
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE
        )
        val st = SurfaceTexture(oesTex)
        st.setDefaultBufferSize(width, height)
        oesSt = st
        st.setOnFrameAvailableListener({ requestRender() }, handler)
        cameraSurface = Surface(st)

        frameW = width
        frameH = height
        log("美顏管線就緒 ${width}x${height}（零 FBO 單 pass）")
    }

    private fun renderFrame() {
        try {
            if (released) return
            val core = egl ?: return
            val st = oesSt ?: return
            val outEncoder = encoderEgl
            val outPreview = previewEgl
            val target = outEncoder ?: outPreview
            val current = target ?: dummyEgl ?: return
            if (!core.makeCurrent(current)) return

            st.updateTexImage()
            st.getTransformMatrix(texMatrix)
            if (!matrixLogged) {
                matrixLogged = true
                android.util.Log.d("BeautyGL", "texMatrix=" + texMatrix.joinToString(","))
            }
            if (target == null) return
            val p = params.normalized()

            if (outEncoder != null) drawOut(core, outEncoder, frameW, frameH, p, true)
            if (outPreview != null) drawOut(core, outPreview, viewW, viewH, p, false)
        } catch (e: Exception) {
            log("美顏渲染錯誤：${e.message}")
            android.util.Log.e("BeautyGL", "render", e)
        } finally {
            pending.set(false)
            if (again.compareAndSet(true, false)) requestRender()
        }
    }

    private fun drawOut(core: EglCore, target: EGLSurface, w: Int, h: Int, p: BeautyParams, encoder: Boolean) {
        if (w <= 0 || h <= 0) return
        if (!core.makeCurrent(target)) return
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        GLES20.glViewport(0, 0, w, h)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

        val program = if (p.hasEffect) progFinal else progOes
        GLES20.glUseProgram(program)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTex)
        GLES20.glUniform1i(GLES20.glGetUniformLocation(program, "uTex"), 0)
        val rot = if (encoder) 0f else previewRot.toFloat()
        GLES20.glUniform1f(GLES20.glGetUniformLocation(program, "uRot"), rot)
        GLES20.glUniform1f(GLES20.glGetUniformLocation(program, "uFlipY"), 1f)

        val s = if (encoder) floatArrayOf(1f, 1f) else coverScale(w, h, previewRot)
        GLES20.glUniform2f(GLES20.glGetUniformLocation(program, "uScale"), s[0], s[1])

        if (p.hasEffect) {
            GLES20.glUniform2f(
                GLES20.glGetUniformLocation(program, "uTexel"),
                1f / frameW, 1f / frameH
            )
            GLES20.glUniform1f(GLES20.glGetUniformLocation(program, "uSmooth"), p.smooth)
            GLES20.glUniform1f(GLES20.glGetUniformLocation(program, "uSharpen"), p.sharpen)
            GLES20.glUniform1f(GLES20.glGetUniformLocation(program, "uWhite"), p.white)
            GLES20.glUniform1f(GLES20.glGetUniformLocation(program, "uPink"), p.pink)
            GLES20.glUniform4f(
                GLES20.glGetUniformLocation(program, "uFace"),
                p.faceCx, p.faceCy, p.faceRx, p.faceRy
            )
        }

        GlProgram.drawQuad(program)

        core.setPresentationTime(target, System.nanoTime())
        if (!core.swapBuffers(target)) {
            android.util.Log.e("BeautyGL", "swapBuffers failed")
        }
    }

    private fun coverScale(w: Int, h: Int, rot: Int): FloatArray {
        val swap = rot % 180 != 0
        val fw = if (swap) frameH else frameW
        val fh = if (swap) frameW else frameH
        val fa = fw.toFloat() / fh
        val va = w.toFloat() / h
        return if (fa > va) floatArrayOf(fa / va, 1f) else floatArrayOf(1f, va / fa)
    }

    private fun releasePreview() {
        val core = egl
        if (core != null && previewEgl != null) {
            core.releaseSurface(previewEgl)
        }
        previewEgl = null
        previewSurface = null
    }

    private fun releaseEncoder() {
        val core = egl
        if (core != null && encoderEgl != null) {
            core.releaseSurface(encoderEgl)
        }
        encoderEgl = null
    }

    fun release(sync: Boolean = false) {
        if (released) return
        released = true
        val job = Runnable {
            try {
                releasePreview()
                releaseEncoder()
                if (progOes != 0) GLES20.glDeleteProgram(progOes)
                if (progFinal != 0) GLES20.glDeleteProgram(progFinal)
                if (oesTex != 0) GlProgram.deleteTexture(oesTex)
                try { oesSt?.release() } catch (_: Exception) {}
                try { cameraSurface?.release() } catch (_: Exception) {}
                egl?.release()
            } catch (_: Exception) {}
            thread.quitSafely()
        }
        if (!sync) {
            handler.post(job)
            return
        }
        val latch = CountDownLatch(1)
        handler.post {
            try {
                job.run()
            } finally {
                latch.countDown()
            }
        }
        try {
            latch.await(900, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
        }
    }
}

