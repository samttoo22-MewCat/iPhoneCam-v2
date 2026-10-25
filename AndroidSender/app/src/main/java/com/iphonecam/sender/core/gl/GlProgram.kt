package com.iphonecam.sender.core.gl

import android.opengl.GLES20
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

object GlProgram {

    private val QUAD = floatArrayOf(
        -1f, -1f, 0f, 0f,
        1f, -1f, 1f, 0f,
        -1f, 1f, 0f, 1f,
        1f, 1f, 1f, 1f
    )

    private val quadBuf: FloatBuffer = ByteBuffer
        .allocateDirect(QUAD.size * 4)
        .order(ByteOrder.nativeOrder())
        .asFloatBuffer()
        .apply { put(QUAD); position(0) }

    fun build(vertexSrc: String, fragmentSrc: String): Int {
        val vs = compile(GLES20.GL_VERTEX_SHADER, vertexSrc)
        val fs = compile(GLES20.GL_FRAGMENT_SHADER, fragmentSrc)
        val p = GLES20.glCreateProgram()
        GLES20.glAttachShader(p, vs)
        GLES20.glAttachShader(p, fs)
        GLES20.glLinkProgram(p)
        val st = IntArray(1)
        GLES20.glGetProgramiv(p, GLES20.GL_LINK_STATUS, st, 0)
        GLES20.glDeleteShader(vs)
        GLES20.glDeleteShader(fs)
        if (st[0] == 0) {
            val log = GLES20.glGetProgramInfoLog(p)
            GLES20.glDeleteProgram(p)
            throw IllegalStateException("link failed: $log")
        }
        return p
    }

    private fun compile(type: Int, src: String): Int {
        val s = GLES20.glCreateShader(type)
        GLES20.glShaderSource(s, src)
        GLES20.glCompileShader(s)
        val st = IntArray(1)
        GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, st, 0)
        if (st[0] == 0) {
            val log = GLES20.glGetShaderInfoLog(s)
            GLES20.glDeleteShader(s)
            throw IllegalStateException("compile failed: $log")
        }
        return s
    }

    fun texture(width: Int, height: Int, linear: Boolean = true): Int {
        val t = IntArray(1)
        GLES20.glGenTextures(1, t, 0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, t[0])
        val filter = if (linear) GLES20.GL_LINEAR else GLES20.GL_NEAREST
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, filter)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, filter)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexImage2D(
            GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, width, height, 0,
            GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null
        )
        return t[0]
    }

    fun framebuffer(texture: Int): Int {
        val f = IntArray(1)
        GLES20.glGenFramebuffers(1, f, 0)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, f[0])
        GLES20.glFramebufferTexture2D(
            GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0,
            GLES20.GL_TEXTURE_2D, texture, 0
        )
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        return f[0]
    }

    fun deleteTexture(id: Int) {
        if (id != 0) GLES20.glDeleteTextures(1, intArrayOf(id), 0)
    }

    fun deleteFramebuffer(id: Int) {
        if (id != 0) GLES20.glDeleteFramebuffers(1, intArrayOf(id), 0)
    }

    fun drawQuad(program: Int) {
        val pos = GLES20.glGetAttribLocation(program, "aPos")
        val tex = GLES20.glGetAttribLocation(program, "aTex")
        quadBuf.position(0)
        if (pos >= 0) {
            GLES20.glVertexAttribPointer(pos, 2, GLES20.GL_FLOAT, false, 16, quadBuf)
            GLES20.glEnableVertexAttribArray(pos)
        }
        if (tex >= 0) {
            quadBuf.position(2)
            GLES20.glVertexAttribPointer(tex, 2, GLES20.GL_FLOAT, false, 16, quadBuf)
            GLES20.glEnableVertexAttribArray(tex)
        }
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        if (pos >= 0) GLES20.glDisableVertexAttribArray(pos)
        if (tex >= 0) GLES20.glDisableVertexAttribArray(tex)
    }
}
