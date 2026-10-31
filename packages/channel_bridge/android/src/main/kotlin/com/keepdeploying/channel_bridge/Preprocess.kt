package com.keepdeploying.channel_bridge

import java.nio.FloatBuffer

/**
 * Bilinear resize of a tightly packed RGBA8888 frame to [size] x [size], RGB
 * order, row-major, written as floats in [-1, 1] (`v / 127.5 - 1`).
 *
 * Sampling uses pixel centres (the "half-pixel" convention):
 * `src = (dst + 0.5) * scale - 0.5`, clamped to the frame. The Dart and C
 * preprocessors in the app use the same rule, so all paths feed the model the
 * same tensor. Alpha is ignored.
 */
internal fun preprocessRgba(rgba: ByteArray, width: Int, height: Int, size: Int, out: FloatBuffer) {
    require(width > 0 && height > 0) { "empty frame: ${width}x$height" }
    require(rgba.size >= width * height * 4) { "rgba has ${rgba.size} bytes, need ${width * height * 4}" }
    require(out.capacity() >= size * size * 3) { "output buffer too small" }

    val scaleX = width.toFloat() / size
    val scaleY = height.toFloat() / size
    val maxX = (width - 1).toFloat()
    val maxY = (height - 1).toFloat()
    var o = 0
    for (y in 0 until size) {
        val fy = ((y + 0.5f) * scaleY - 0.5f).coerceIn(0f, maxY)
        val y0 = fy.toInt()
        val y1 = minOf(y0 + 1, height - 1)
        val wy = fy - y0
        for (x in 0 until size) {
            val fx = ((x + 0.5f) * scaleX - 0.5f).coerceIn(0f, maxX)
            val x0 = fx.toInt()
            val x1 = minOf(x0 + 1, width - 1)
            val wx = fx - x0
            val i00 = (y0 * width + x0) * 4
            val i01 = (y0 * width + x1) * 4
            val i10 = (y1 * width + x0) * 4
            val i11 = (y1 * width + x1) * 4
            for (c in 0 until 3) {
                val top = (rgba[i00 + c].toInt() and 0xFF) * (1f - wx) + (rgba[i01 + c].toInt() and 0xFF) * wx
                val bottom = (rgba[i10 + c].toInt() and 0xFF) * (1f - wx) + (rgba[i11 + c].toInt() and 0xFF) * wx
                val v = top * (1f - wy) + bottom * wy
                out.put(o++, v / 127.5f - 1f)
            }
        }
    }
}
