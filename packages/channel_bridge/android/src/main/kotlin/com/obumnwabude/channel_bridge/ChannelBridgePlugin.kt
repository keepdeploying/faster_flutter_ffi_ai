package com.obumnwabude.channel_bridge

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BasicMessageChannel
import io.flutter.plugin.common.BinaryCodec
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

// LiteRT runtime: com.google.ai.edge.litert:litert:1.4.2 (see android/build.gradle.kts).
//
// The two Flutter channels of the demo. Names, methods and reply shapes are the
// contract in docs/ARCHITECTURE.md; the Dart side is lib/src/*.dart.
//
// What happens underneath, per call:
//  - "faster_flutter/method": StandardMessageCodec decodes the call on the
//    platform thread (the Uint8List becomes a ByteArray: one copy), the handler
//    runs there, and the reply is encoded again.
//  - "faster_flutter/binary": BinaryCodec.INSTANCE_DIRECT hands the handler a
//    direct ByteBuffer over the engine's own memory, with no decode and no
//    copy. The reply is a 4-byte direct buffer.
//  - classify: the frame arrives like the method payload, then the work moves to
//    a single background thread (site "background") and the reply is posted
//    back to the platform thread. Site "platform" runs it right in the handler
//    so the jank demo can show what that costs.
class ChannelBridgePlugin : FlutterPlugin {
    private var methodChannel: MethodChannel? = null
    private var binaryChannel: BasicMessageChannel<ByteBuffer>? = null
    private var appContext: Context? = null
    private var assets: FlutterPlugin.FlutterAssets? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private var worker: ExecutorService? = null

    // Written on the platform thread by loadModel, read on the worker or
    // platform thread by classify. @Volatile makes the hand-off safe.
    @Volatile
    private var classifier: Classifier? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        assets = binding.flutterAssets
        worker = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "channel_bridge-classify") }

        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).also {
            it.setMethodCallHandler { call, result -> onMethodCall(call, result) }
        }
        binaryChannel = BasicMessageChannel(binding.binaryMessenger, BINARY_CHANNEL, BinaryCodec.INSTANCE_DIRECT).also {
            it.setMessageHandler { message, reply -> reply.reply(checksumReply(message)) }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        binaryChannel?.setMessageHandler(null)
        methodChannel = null
        binaryChannel = null
        worker?.shutdown()
        worker = null
        // The worker may still be inside classify(); closing waits for no one, so
        // let go of the reference and let the interpreter be collected with it.
        classifier = null
        appContext = null
        assets = null
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "roundTrip" -> {
                val bytes = call.arguments as? ByteArray
                if (bytes == null) {
                    result.error("bad_arguments", "roundTrip expects a Uint8List", null)
                } else {
                    result.success(checksum(bytes))
                }
            }
            "loadModel" -> loadModel(call, result)
            "classify" -> classify(call, result)
            else -> result.notImplemented()
        }
    }

    /** The 4-byte little-endian checksum reply. Position stays at 4: the engine reads the length from it. */
    private fun checksumReply(message: ByteBuffer?): ByteBuffer {
        val sum = if (message == null) 0L else checksum(message)
        return ByteBuffer.allocateDirect(4).order(ByteOrder.LITTLE_ENDIAN).putInt(sum.toInt())
    }

    private fun loadModel(call: MethodCall, result: MethodChannel.Result) {
        val modelKey = call.argument<String>("model")
        val labelsKey = call.argument<String>("labels")
        val threads = call.argument<Int>("threads") ?: DEFAULT_THREADS
        val context = appContext
        val flutterAssets = assets
        val executor = worker
        if (modelKey == null || labelsKey == null || context == null || flutterAssets == null || executor == null) {
            result.error("bad_arguments", "loadModel expects {model, labels, threads}", null)
            return
        }
        // getAssetFilePathByName is FlutterLoader.getLookupKeyForAsset under the hood.
        val modelPath = flutterAssets.getAssetFilePathByName(modelKey)
        val labelsPath = flutterAssets.getAssetFilePathByName(labelsKey)
        // Load on the worker thread: the model file is 17 MB. Because classify also
        // runs there, the old interpreter is never closed in the middle of a call.
        executor.execute {
            val outcome = runCatching {
                // The interpreter needs a direct buffer in native byte order.
                val modelBytes = context.assets.open(modelPath).use { it.readBytes() }
                val model = ByteBuffer.allocateDirect(modelBytes.size).order(ByteOrder.nativeOrder())
                model.put(modelBytes)
                model.rewind()
                val labels = context.assets.open(labelsPath).bufferedReader().use { it.readLines() }

                val previous = classifier
                classifier = Classifier(model, labels, threads)
                previous?.close()
            }
            mainHandler.post {
                val error = outcome.exceptionOrNull()
                if (error == null) {
                    result.success(null)
                } else {
                    result.error("load_failed", error.message ?: error.toString(), null)
                }
            }
        }
    }

    private fun classify(call: MethodCall, result: MethodChannel.Result) {
        val rgba = call.argument<ByteArray>("rgba")
        val width = call.argument<Int>("width")
        val height = call.argument<Int>("height")
        val onPlatformThread = call.argument<String>("site") == "platform"
        val current = classifier
        if (rgba == null || width == null || height == null) {
            result.error("bad_arguments", "classify expects {rgba, width, height}", null)
            return
        }
        if (current == null) {
            result.error("not_loaded", "call loadModel first", null)
            return
        }

        if (onPlatformThread) {
            // Blocks the platform thread, and with merged threads the UI thread, until done.
            deliver(result, runCatching { current.classify(rgba, width, height) })
            return
        }
        val executor = worker
        if (executor == null) {
            result.error("detached", "the plugin is detached from the engine", null)
            return
        }
        executor.execute {
            // Compute here, then answer on the platform thread: MethodChannel.Result
            // must be used from the thread the call arrived on.
            val outcome = runCatching { current.classify(rgba, width, height) }
            mainHandler.post { deliver(result, outcome) }
        }
    }

    private fun deliver(result: MethodChannel.Result, outcome: Result<ClassifyResult>) {
        val value = outcome.getOrNull()
        if (value == null) {
            val error = outcome.exceptionOrNull()
            result.error("classify_failed", error?.message ?: error.toString(), null)
            return
        }
        result.success(
            mapOf(
                "index" to value.index,
                "label" to value.label,
                "confidence" to value.confidence,
                "preprocessUs" to value.preprocessMicros,
                "inferenceUs" to value.inferenceMicros,
            ),
        )
    }

    private companion object {
        const val METHOD_CHANNEL = "faster_flutter/method"
        const val BINARY_CHANNEL = "faster_flutter/binary"
        const val DEFAULT_THREADS = 4
    }
}
