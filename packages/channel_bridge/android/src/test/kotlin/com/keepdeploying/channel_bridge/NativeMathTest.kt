package com.keepdeploying.channel_bridge

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.test.Test
import kotlin.test.assertEquals

/** JVM tests for the checksum (when libffi_bridge.so can load) and the resize. Run with `./gradlew testDebugUnitTest`. */
internal class NativeMathTest {
    @Test
    fun checksumIsTheByteSumModulo2Pow32() {
        // checksum() runs ffb_checksum from libffi_bridge.so, which only exists
        // inside the app. On a plain JVM there is nothing to test here.
        if (!nativeChecksumLoaded) return
        assertEquals(0L, checksum(ByteArray(0)))
        assertEquals(255L * 3, checksum(byteArrayOf(-1, -1, -1)))
        // 20 million bytes of 0xFF is 5,100,000,000, which wraps once past 2^32.
        val big = ByteArray(20_000_000) { -1 }
        assertEquals(20_000_000L * 255 % (1L shl 32), checksum(big))
    }

    @Test
    fun bufferChecksumMatchesAndKeepsPosition() {
        if (!nativeChecksumLoaded) return
        val bytes = ByteArray(1000) { (it * 31 + 7).toByte() }
        val buffer = ByteBuffer.allocateDirect(bytes.size).put(bytes)
        buffer.rewind()
        assertEquals(checksum(bytes), checksum(buffer))
        assertEquals(0, buffer.position())
    }

    @Test
    fun preprocessMapsBlackAndWhiteToMinusOneAndOne() {
        val white = ByteArray(8 * 6 * 4) { -1 }
        val out = ByteBuffer.allocateDirect(4 * 4 * 3 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
        preprocessRgba(white, 8, 6, 4, out)
        for (i in 0 until 4 * 4 * 3) assertEquals(1f, out.get(i), 1e-6f)

        val black = ByteArray(8 * 6 * 4)
        preprocessRgba(black, 8, 6, 4, out)
        for (i in 0 until 4 * 4 * 3) assertEquals(-1f, out.get(i), 1e-6f)
    }

    @Test
    fun preprocessInterpolatesBetweenPixels() {
        // A 2x1 frame: left pixel 0, right pixel 255 (red channel). Scale to 2x2 keeps the
        // pixel centres, so the left column stays at -1 and the right at +1.
        val rgba = byteArrayOf(0, 0, 0, -1, -1, 0, 0, -1)
        val out = ByteBuffer.allocateDirect(2 * 2 * 3 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
        preprocessRgba(rgba, 2, 1, 2, out)
        assertEquals(-1f, out.get(0), 1e-6f) // x=0, red
        assertEquals(1f, out.get(3), 1e-6f) // x=1, red
        assertEquals(-1f, out.get(1), 1e-6f) // green stays at 0 -> -1
    }
}
