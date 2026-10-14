// The TensorFlow Lite C API, reached through the symbols that are already loaded in
// this process. No build-time dependency on any TensorFlow Lite binary.
//
// Why: the app also depends on flutter_litert, which links TensorFlowLiteC.framework
// and whose Dart side calls it with `DynamicLibrary.process()`, that is
// dlsym(RTLD_DEFAULT, ...). This file does the same lookup from Swift, so the channel
// path and the FFI path run the very same compiled runtime. See the README of the
// package ("iOS: where the runtime comes from") for why a second copy was rejected.
//
// Only Foundation-free code here, so the file also compiles on Linux for the unit test.

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

/// An error with a code that becomes the `FlutterError` code on the Dart side.
struct BridgeError: Error, CustomStringConvertible {
  let code: String
  let message: String
  var description: String { message }
}

/// Looks a C symbol up by name in the whole process, or returns nil.
typealias SymbolLookup = (String) -> UnsafeMutableRawPointer?

/// The handle that means "search every loaded image". It is a function, not a global,
/// so the file also compiles in the Swift 6 language mode.
private func rtldDefault() -> UnsafeMutableRawPointer? {
  #if canImport(Darwin)
    // RTLD_DEFAULT on Darwin is the pseudo-handle -2.
    return UnsafeMutableRawPointer(bitPattern: -2)
  #else
    // RTLD_DEFAULT on glibc is a null handle.
    return nil
  #endif
}

/// The production lookup: dlsym(RTLD_DEFAULT, name). Same as `DynamicLibrary.process()`
/// in Dart.
func processSymbolLookup(_ name: String) -> UnsafeMutableRawPointer? {
  dlsym(rtldDefault(), name)
}

/// The twenty C API entry points the classifier needs (tensorflow/lite/c/c_api.h),
/// as `@convention(c)` function values. Opaque C handles are raw pointers.
///
/// Types, from c_api.h (TFLite 2.x):
///  - `size_t` is `Int` here (same width and calling convention on arm64),
///  - `int32_t` is `Int32`,
///  - `TfLiteStatus` and `TfLiteType` are C enums, which arm64 passes as 32-bit ints.
struct TfLiteAPI {
  typealias Handle = UnsafeMutableRawPointer

  /// `kTfLiteOk`.
  static let statusOk: Int32 = 0
  /// `kTfLiteFloat32`.
  static let typeFloat32: Int32 = 1

  let version: @convention(c) () -> UnsafePointer<CChar>?
  let modelCreate: @convention(c) (UnsafeRawPointer?, Int) -> Handle?
  let modelDelete: @convention(c) (Handle?) -> Void
  let optionsCreate: @convention(c) () -> Handle?
  let optionsDelete: @convention(c) (Handle?) -> Void
  let optionsSetNumThreads: @convention(c) (Handle?, Int32) -> Void
  let interpreterCreate: @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?) -> Handle?
  let interpreterDelete: @convention(c) (Handle?) -> Void
  let allocateTensors: @convention(c) (Handle?) -> Int32
  let invoke: @convention(c) (Handle?) -> Int32
  let inputTensorCount: @convention(c) (UnsafeRawPointer?) -> Int32
  let outputTensorCount: @convention(c) (UnsafeRawPointer?) -> Int32
  let inputTensor: @convention(c) (UnsafeRawPointer?, Int32) -> Handle?
  let outputTensor: @convention(c) (UnsafeRawPointer?, Int32) -> Handle?
  let tensorType: @convention(c) (UnsafeRawPointer?) -> Int32
  let tensorNumDims: @convention(c) (UnsafeRawPointer?) -> Int32
  let tensorDim: @convention(c) (UnsafeRawPointer?, Int32) -> Int32
  let tensorByteSize: @convention(c) (UnsafeRawPointer?) -> Int
  let tensorCopyFromBuffer: @convention(c) (Handle?, UnsafeRawPointer?, Int) -> Int32
  let tensorCopyToBuffer: @convention(c) (UnsafeRawPointer?, UnsafeMutableRawPointer?, Int) -> Int32

  private static let symbolNames = [
    "TfLiteVersion",
    "TfLiteModelCreate", "TfLiteModelDelete",
    "TfLiteInterpreterOptionsCreate", "TfLiteInterpreterOptionsDelete",
    "TfLiteInterpreterOptionsSetNumThreads",
    "TfLiteInterpreterCreate", "TfLiteInterpreterDelete",
    "TfLiteInterpreterAllocateTensors", "TfLiteInterpreterInvoke",
    "TfLiteInterpreterGetInputTensorCount", "TfLiteInterpreterGetOutputTensorCount",
    "TfLiteInterpreterGetInputTensor", "TfLiteInterpreterGetOutputTensor",
    "TfLiteTensorType", "TfLiteTensorNumDims", "TfLiteTensorDim", "TfLiteTensorByteSize",
    "TfLiteTensorCopyFromBuffer", "TfLiteTensorCopyToBuffer",
  ]

  /// Resolves every symbol or throws one error that names all the missing ones.
  init(lookup: SymbolLookup = processSymbolLookup) throws {
    let missing = TfLiteAPI.symbolNames.filter { lookup($0) == nil }
    guard missing.isEmpty else {
      throw BridgeError(
        code: "runtime_missing",
        message:
          "The TensorFlow Lite C runtime is not loaded in this process (missing: "
          + missing.joined(separator: ", ")
          + "). channel_bridge uses the copy that flutter_litert links on iOS. "
          + "Add flutter_litert to the app's dependencies and make sure it is used "
          + "(its iOS plugin keeps the symbols alive).")
    }
    func symbol<T>(_ name: String) -> T {
      unsafeBitCast(lookup(name)!, to: T.self)
    }
    version = symbol("TfLiteVersion")
    modelCreate = symbol("TfLiteModelCreate")
    modelDelete = symbol("TfLiteModelDelete")
    optionsCreate = symbol("TfLiteInterpreterOptionsCreate")
    optionsDelete = symbol("TfLiteInterpreterOptionsDelete")
    optionsSetNumThreads = symbol("TfLiteInterpreterOptionsSetNumThreads")
    interpreterCreate = symbol("TfLiteInterpreterCreate")
    interpreterDelete = symbol("TfLiteInterpreterDelete")
    allocateTensors = symbol("TfLiteInterpreterAllocateTensors")
    invoke = symbol("TfLiteInterpreterInvoke")
    inputTensorCount = symbol("TfLiteInterpreterGetInputTensorCount")
    outputTensorCount = symbol("TfLiteInterpreterGetOutputTensorCount")
    inputTensor = symbol("TfLiteInterpreterGetInputTensor")
    outputTensor = symbol("TfLiteInterpreterGetOutputTensor")
    tensorType = symbol("TfLiteTensorType")
    tensorNumDims = symbol("TfLiteTensorNumDims")
    tensorDim = symbol("TfLiteTensorDim")
    tensorByteSize = symbol("TfLiteTensorByteSize")
    tensorCopyFromBuffer = symbol("TfLiteTensorCopyFromBuffer")
    tensorCopyToBuffer = symbol("TfLiteTensorCopyToBuffer")
  }

  /// The runtime's own version string, e.g. "2.x.y", for error messages.
  var versionString: String {
    version().map { String(cString: $0) } ?? "unknown"
  }
}
