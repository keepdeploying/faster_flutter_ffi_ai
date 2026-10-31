package com.keepdeploying.channel_bridge

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import java.util.concurrent.atomic.AtomicLong

// JNI shims live in packages/llm_bridge/src/llm_bridge.cpp, named
// `Java_com_keepdeploying_channel_1bridge_LlamaChannelKt_nativeXxx`. Top-level
// `external fun` keeps the JNI symbol names short; a private file facade class
// (`LlamaChannelKt`) carries the static methods JNI binds to. loadLibraryOnce
// below is referenced from the LlamaChannel constructor so libllm_bridge is
// loaded before any extern is called.
private val loadLibraryOnce: Unit = System.loadLibrary("llm_bridge")

private external fun nativeLoad(
    path: String,
    contextSize: Int,
    threads: Int,
    errBuf: ByteArray,
    errBufLen: Int,
): Long

private external fun nativeFreeModel(handle: Long)

private external fun nativePromptPull(
    handle: Long,
    prompt: String,
    maxTokens: Int,
    temperature: Float,
    seed: Long,
): Long

private external fun nativePullNextToken(streamId: Long): String?

private external fun nativeCancel(handle: Long, streamId: Long)

/**
 * The llama.cpp side of the demo, reached over an EventChannel.
 *
 * The native library `libllm_bridge.so` is produced by the llm_bridge build
 * hook for every target; the Dart FFI path and this Kotlin path both call the
 * same compiled copy. The subset of the C ABI used here is the pull model
 * added in llm_bridge.h: `llb_prompt_pull` starts a generation whose tokens
 * land in an internal queue, and `llb_pull_next_token` blocks until the next
 * token (or NULL at end of stream). That shape fits a background thread
 * forwarding tokens to an EventSink one by one.
 *
 * One model is cached per instance, keyed by modelPath. A new path frees the
 * old handle; the lock prevents a load and a generation from racing.
 */
internal class LlamaChannel {
    init {
        // Touch the top-level `val` to run its initializer once per process.
        loadLibraryOnce
    }

    companion object {
        const val CHANNEL_NAME = "faster_flutter/llm"
        private const val ERR_BUF_LEN = 512
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val modelLock = Any()

    // Cached model handle. Written under `modelLock`.
    private var modelPath: String? = null
    private var modelHandle: Long = 0L

    // The active stream, so onCancel can stop it. Updated by the worker thread
    // and the platform thread; AtomicLong gives a safe hand-off.
    private val activeStream = AtomicLong(0L)
    private val activeHandle = AtomicLong(0L)

    @Volatile private var worker: Thread? = null

    private var channel: EventChannel? = null

    fun register(messenger: BinaryMessenger) {
        val eventChannel = EventChannel(messenger, CHANNEL_NAME)
        eventChannel.setStreamHandler(streamHandler)
        channel = eventChannel
    }

    fun unregister() {
        channel?.setStreamHandler(null)
        channel = null
        stopActiveStream()
        synchronized(modelLock) {
            if (modelHandle != 0L) {
                nativeFreeModel(modelHandle)
                modelHandle = 0L
                modelPath = null
            }
        }
    }

    private val streamHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
            val args = arguments as? Map<*, *>
            val path = args?.get("modelPath") as? String
            val prompt = args?.get("prompt") as? String
            if (path == null || prompt == null) {
                events.error("bad_arguments", "generate expects {modelPath, prompt}", null)
                events.endOfStream()
                return
            }
            val contextSize = (args["contextSize"] as? Number)?.toInt() ?: 1024
            val threads = (args["threads"] as? Number)?.toInt() ?: 4
            val maxTokens = (args["maxTokens"] as? Number)?.toInt() ?: 128
            val temperature = (args["temperature"] as? Number)?.toFloat() ?: 0.0f
            val seed = (args["seed"] as? Number)?.toLong() ?: 0L

            val thread = Thread({
                runGeneration(
                    path = path,
                    contextSize = contextSize,
                    threads = threads,
                    prompt = prompt,
                    maxTokens = maxTokens,
                    temperature = temperature,
                    seed = seed,
                    events = events,
                )
            }, "channel_bridge-llama")
            worker = thread
            thread.start()
        }

        override fun onCancel(arguments: Any?) {
            stopActiveStream()
        }
    }

    private fun stopActiveStream() {
        val stream = activeStream.get()
        val handle = activeHandle.get()
        if (stream != 0L && handle != 0L) {
            nativeCancel(handle, stream)
        }
    }

    private fun runGeneration(
        path: String,
        contextSize: Int,
        threads: Int,
        prompt: String,
        maxTokens: Int,
        temperature: Float,
        seed: Long,
        events: EventChannel.EventSink,
    ) {
        val handle: Long
        try {
            handle = ensureModel(path, contextSize, threads)
        } catch (error: Throwable) {
            postError(events, "load_failed", error.message ?: error.toString())
            postEnd(events)
            return
        }

        val streamId = nativePromptPull(handle, prompt, maxTokens, temperature, seed)
        if (streamId <= 0L) {
            postError(events, "generate_failed", "llb_prompt_pull returned $streamId")
            postEnd(events)
            return
        }
        activeHandle.set(handle)
        activeStream.set(streamId)
        try {
            while (true) {
                val token = nativePullNextToken(streamId) ?: break
                postToken(events, token)
            }
        } finally {
            activeStream.set(0L)
            activeHandle.set(0L)
            postEnd(events)
        }
    }

    private fun ensureModel(path: String, contextSize: Int, threads: Int): Long {
        synchronized(modelLock) {
            if (modelHandle != 0L && modelPath == path) return modelHandle
            if (modelHandle != 0L) {
                nativeFreeModel(modelHandle)
                modelHandle = 0L
                modelPath = null
            }
            val errBuf = ByteArray(ERR_BUF_LEN)
            val handle = nativeLoad(path, contextSize, threads, errBuf, ERR_BUF_LEN)
            if (handle == 0L) {
                val end = errBuf.indexOf(0).let { if (it < 0) errBuf.size else it }
                val message = String(errBuf, 0, end, Charsets.UTF_8)
                throw RuntimeException(if (message.isEmpty()) "llb_load returned null" else message)
            }
            modelHandle = handle
            modelPath = path
            return handle
        }
    }

    private fun postToken(events: EventChannel.EventSink, token: String) {
        mainHandler.post { events.success(token) }
    }

    private fun postError(events: EventChannel.EventSink, code: String, message: String) {
        mainHandler.post { events.error(code, message, null) }
    }

    private fun postEnd(events: EventChannel.EventSink) {
        mainHandler.post { events.endOfStream() }
    }
}
