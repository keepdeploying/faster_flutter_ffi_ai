package com.keepdeploying.channel_bridge

import java.nio.ByteBuffer

/**
 * The byte sum modulo 2^32, the same as `checksum()` in Dart and Swift.
 *
 * It returns a Long so the value stays positive; the method channel sends it
 * as a 64-bit integer and Dart reads it as an int.
 */
internal fun checksum(bytes: ByteArray): Long {
    var sum = 0L
    for (b in bytes) {
        sum += b.toLong() and 0xFF
    }
    return sum and 0xFFFFFFFFL
}

/**
 * Same sum over a buffer, from position to limit. It uses absolute reads, so
 * the buffer's position does not move. With `BinaryCodec.INSTANCE_DIRECT` the
 * buffer points straight at the engine's memory and is only valid until the
 * handler returns.
 */
internal fun checksum(buffer: ByteBuffer): Long {
    var sum = 0L
    for (i in buffer.position() until buffer.limit()) {
        sum += buffer.get(i).toLong() and 0xFF
    }
    return sum and 0xFFFFFFFFL
}
