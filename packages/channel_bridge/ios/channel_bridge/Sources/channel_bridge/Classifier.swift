// The Swift twin of Classifier.kt: a float MobileNet (1 x N x N x 3 input in [-1, 1],
// one score per label out) run through the TensorFlow Lite C API.
//
// No Flutter import, so the file compiles on Linux for the unit test.

import Dispatch
import Foundation

/// One result with the time split, measured here with the monotonic clock.
struct ClassifyResult {
  let index: Int
  let label: String
  let confidence: Double
  let preprocessMicros: Int
  let inferenceMicros: Int
}

/// Owns one TFLite model + interpreter. A call to `classify` holds a lock, so two
/// threads never use the interpreter at the same time (the plugin only uses it from
/// its serial queue, or, for the jank demo, from the main thread). The C objects are
/// freed in `deinit`, which runs only after the last in-flight `classify` has
/// returned: replacing the classifier while a call is running is safe.
final class Classifier: @unchecked Sendable {
  private let api: TfLiteAPI
  private let lock = NSLock()

  // The C API borrows the model bytes for the interpreter's whole life, so they are
  // copied once into memory this object owns.
  private let modelData: UnsafeMutableRawPointer
  private var model: UnsafeMutableRawPointer?
  private var interpreter: UnsafeMutableRawPointer?
  private let inputTensor: UnsafeMutableRawPointer
  private let outputTensor: UnsafeMutableRawPointer

  private let labels: [String]
  private let size: Int
  private let inputCount: Int
  private let inputBytes: Int
  private let inputFloats: UnsafeMutablePointer<Float>
  private let scoreCount: Int
  private let scoreBytes: Int
  private let scores: UnsafeMutablePointer<Float>

  init(api: TfLiteAPI, modelBytes: UnsafeRawBufferPointer, labels: [String], threads: Int) throws {
    guard let source = modelBytes.baseAddress, modelBytes.count > 0 else {
      throw BridgeError(code: "load_failed", message: "the model file is empty")
    }
    self.api = api
    self.labels = labels

    let data = UnsafeMutableRawPointer.allocate(byteCount: modelBytes.count, alignment: 64)
    data.copyMemory(from: source, byteCount: modelBytes.count)
    var model: UnsafeMutableRawPointer? = nil
    var interpreter: UnsafeMutableRawPointer? = nil
    // Everything allocated so far is released if a check below throws.
    func release() {
      if let interpreter { api.interpreterDelete(interpreter) }
      if let model { api.modelDelete(model) }
      data.deallocate()
    }
    func fail(_ message: String) -> BridgeError {
      release()
      return BridgeError(code: "load_failed", message: message)
    }

    model = api.modelCreate(data, modelBytes.count)
    guard model != nil else {
      throw fail("TfLiteModelCreate failed: not a valid .tflite file (runtime \(api.versionString))")
    }
    guard let options = api.optionsCreate() else {
      throw fail("TfLiteInterpreterOptionsCreate failed")
    }
    api.optionsSetNumThreads(options, Int32(max(1, threads)))
    interpreter = api.interpreterCreate(model, options)
    api.optionsDelete(options)
    guard interpreter != nil else {
      throw fail("TfLiteInterpreterCreate failed (runtime \(api.versionString))")
    }
    guard api.allocateTensors(interpreter) == TfLiteAPI.statusOk else {
      throw fail("TfLiteInterpreterAllocateTensors failed")
    }
    guard api.inputTensorCount(interpreter) >= 1, api.outputTensorCount(interpreter) >= 1,
      let input = api.inputTensor(interpreter, 0),
      let output = api.outputTensor(interpreter, 0)
    else {
      throw fail("the model has no input or no output tensor")
    }

    // The same checks as Classifier.kt.
    guard api.tensorType(input) == TfLiteAPI.typeFloat32 else {
      throw fail("expected a float model, input type is \(api.tensorType(input))")
    }
    let dims = (0..<Int(max(0, api.tensorNumDims(input)))).map { Int(api.tensorDim(input, Int32($0))) }
    guard dims.count == 4, dims[0] == 1, dims[1] == dims[2], dims[3] == 3 else {
      throw fail("expected input 1 x N x N x 3, got \(dims)")
    }
    let size = dims[1]
    let inputCount = size * size * 3
    guard api.tensorByteSize(input) == inputCount * MemoryLayout<Float>.size else {
      throw fail("the input tensor is not \(inputCount) floats")
    }
    let outDims = Int(api.tensorNumDims(output))
    guard outDims >= 1 else {
      throw fail("the output tensor has no shape")
    }
    let classes = Int(api.tensorDim(output, Int32(outDims - 1)))
    guard classes >= 1 && classes == labels.count else {
      throw fail("model has \(classes) outputs but the labels file has \(labels.count) lines")
    }
    guard api.tensorType(output) == TfLiteAPI.typeFloat32,
      api.tensorByteSize(output) == classes * MemoryLayout<Float>.size
    else {
      throw fail("expected one float32 score per label (1 x \(classes))")
    }

    self.modelData = data
    self.model = model
    self.interpreter = interpreter
    self.inputTensor = input
    self.outputTensor = output
    self.size = size
    self.inputCount = inputCount
    self.inputBytes = inputCount * MemoryLayout<Float>.size
    self.inputFloats = UnsafeMutablePointer<Float>.allocate(capacity: inputCount)
    self.inputFloats.initialize(repeating: 0, count: inputCount)
    self.scoreCount = classes
    self.scoreBytes = classes * MemoryLayout<Float>.size
    self.scores = UnsafeMutablePointer<Float>.allocate(capacity: classes)
    self.scores.initialize(repeating: 0, count: classes)
  }

  deinit {
    api.interpreterDelete(interpreter)
    api.modelDelete(model)
    modelData.deallocate()
    inputFloats.deallocate()
    scores.deallocate()
  }

  /// Resizes `rgba` to the model's input, runs the model, returns the best label.
  ///
  /// Timing as in Kotlin: `preprocessMicros` is the resize alone; `inferenceMicros` is
  /// copy in + invoke + copy out, which is what `Interpreter.run(input, output)` does.
  func classify(rgba: UnsafeBufferPointer<UInt8>, width: Int, height: Int) throws -> ClassifyResult {
    lock.lock()
    defer { lock.unlock() }

    let t0 = DispatchTime.now().uptimeNanoseconds
    try preprocessRgba(
      rgba, width: width, height: height, size: size, out: inputFloats, outCapacity: inputCount)
    let t1 = DispatchTime.now().uptimeNanoseconds

    guard api.tensorCopyFromBuffer(inputTensor, inputFloats, inputBytes) == TfLiteAPI.statusOk
    else {
      throw BridgeError(code: "classify_failed", message: "TfLiteTensorCopyFromBuffer failed")
    }
    let status = api.invoke(interpreter)
    guard status == TfLiteAPI.statusOk else {
      throw BridgeError(
        code: "classify_failed", message: "TfLiteInterpreterInvoke failed (status \(status))")
    }
    guard api.tensorCopyToBuffer(outputTensor, scores, scoreBytes) == TfLiteAPI.statusOk else {
      throw BridgeError(code: "classify_failed", message: "TfLiteTensorCopyToBuffer failed")
    }
    let t2 = DispatchTime.now().uptimeNanoseconds

    var best = 0
    for i in 1..<scoreCount where scores[i] > scores[best] {
      best = i
    }
    return ClassifyResult(
      index: best,
      label: labels[best],
      confidence: Double(scores[best]),
      preprocessMicros: Int((t1 - t0) / 1000),
      inferenceMicros: Int((t2 - t1) / 1000))
  }
}

/// Splits a labels file into lines like Kotlin's `readLines`: "\n" or "\r\n" ends a
/// line, and a final newline does not add an empty last line.
func parseLabels(_ text: String) -> [String] {
  var lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
    .map(String.init)
  if lines.last == "" { lines.removeLast() }
  return lines
}
