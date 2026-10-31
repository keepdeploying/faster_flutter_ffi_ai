package com.keepdeploying.channel_bridge

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.tensorflow.lite.DataType
import org.tensorflow.lite.Interpreter

/** One result with the time split, measured here with the monotonic clock. */
internal class ClassifyResult(
    val index: Int,
    val label: String,
    val confidence: Double,
    val preprocessMicros: Long,
    val inferenceMicros: Long,
)

/**
 * Runs a float MobileNet (1 x 224 x 224 x 3 input in [-1, 1], one score per
 * label out) with the LiteRT interpreter.
 *
 * The LiteRT 1.4.x Java API still lives in the `org.tensorflow.lite` package.
 * One instance is used from one thread at a time; the plugin guarantees that
 * with its single-thread executor (or, for the jank demo, the platform thread).
 */
internal class Classifier(
    modelBytes: ByteBuffer,
    private val labels: List<String>,
    threads: Int,
) : AutoCloseable {
    private val interpreter: Interpreter =
        Interpreter(modelBytes, Interpreter.Options().setNumThreads(threads))
    private val size: Int
    private val input: ByteBuffer
    private val inputFloats: java.nio.FloatBuffer
    private val scores: Array<FloatArray>

    init {
        val inputTensor = interpreter.getInputTensor(0)
        val shape = inputTensor.shape()
        check(inputTensor.dataType() == DataType.FLOAT32) {
            "expected a float model, input type is ${inputTensor.dataType()}"
        }
        check(shape.size == 4 && shape[0] == 1 && shape[1] == shape[2] && shape[3] == 3) {
            "expected input 1 x N x N x 3, got ${shape.contentToString()}"
        }
        size = shape[1]
        input = ByteBuffer.allocateDirect(size * size * 3 * 4).order(ByteOrder.nativeOrder())
        inputFloats = input.asFloatBuffer()

        val classes = interpreter.getOutputTensor(0).shape().last()
        check(classes == labels.size) { "model has $classes outputs but the labels file has ${labels.size} lines" }
        scores = arrayOf(FloatArray(classes))
    }

    fun classify(rgba: ByteArray, width: Int, height: Int): ClassifyResult {
        val t0 = System.nanoTime()
        preprocessRgba(rgba, width, height, size, inputFloats)
        input.rewind()
        val t1 = System.nanoTime()
        interpreter.run(input, scores)
        val t2 = System.nanoTime()

        val row = scores[0]
        var best = 0
        for (i in 1 until row.size) {
            if (row[i] > row[best]) best = i
        }
        return ClassifyResult(
            index = best,
            label = labels[best],
            confidence = row[best].toDouble(),
            preprocessMicros = (t1 - t0) / 1000,
            inferenceMicros = (t2 - t1) / 1000,
        )
    }

    override fun close() {
        interpreter.close()
    }
}
