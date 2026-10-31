package com.keepdeploying.channel_bridge

import java.nio.ByteBuffer

// Both channel handlers sum the bytes with the same C function the FFI bridges
// call, `ffb_checksum` in packages/ffi_bridge/src/ffi_bridge.c, through JNI.
// So every bridge in the race does identical work on the native side, and the
// difference you measure is the bridge alone, not Kotlin against C.
//
// The library is the one the ffi_bridge build hook compiles and Flutter packs
// into the APK (lib/<abi>/libffi_bridge.so). The JNI entry points are at the
// end of ffi_bridge.c, named for this file's class, ChecksumKt.
//
// On a plain JVM (the unit tests) the library does not exist, so loading is
// tried once and remembered; the tests skip when it is missing. In the app a
// missing library is a build error, so checksum() fails loudly instead of
// quietly falling back to a Kotlin loop and making the race unfair.
internal val nativeChecksumLoaded: Boolean =
    try {
        System.loadLibrary("ffi_bridge")
        true
    } catch (e: UnsatisfiedLinkError) {
        false
    }

private fun requireNative() =
    check(nativeChecksumLoaded) { "libffi_bridge.so is not in the APK; channel_bridge needs ffi_bridge for its checksum" }

private external fun nativeChecksum(bytes: ByteArray, offset: Int, length: Int): Int

private external fun nativeChecksumDirect(buffer: ByteBuffer, offset: Int, length: Int): Int

/**
 * The byte sum modulo 2^32, computed by `ffb_checksum` in C.
 *
 * It returns a Long so the value stays positive; the method channel sends it
 * as a 64-bit integer and Dart reads it as an int.
 */
internal fun checksum(bytes: ByteArray): Long {
    requireNative()
    return nativeChecksum(bytes, 0, bytes.size).toLong() and 0xFFFFFFFFL
}

/**
 * Same sum over a buffer, from position to limit; the position does not move.
 * With `BinaryCodec.INSTANCE_DIRECT` the buffer is direct and points straight
 * at the engine's memory (valid only until the handler returns), so C reads
 * it in place with no copy.
 */
internal fun checksum(buffer: ByteBuffer): Long {
    requireNative()
    val offset = buffer.position()
    val length = buffer.remaining()
    val sum = when {
        buffer.isDirect -> nativeChecksumDirect(buffer, offset, length)
        buffer.hasArray() -> nativeChecksum(buffer.array(), buffer.arrayOffset() + offset, length)
        else -> {
            val copy = ByteArray(length)
            buffer.duplicate().get(copy)
            nativeChecksum(copy, 0, length)
        }
    }
    return sum.toLong() and 0xFFFFFFFFL
}
