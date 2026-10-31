import Dispatch
import Flutter
import Foundation

/// The two Flutter channels of the demo. Names, methods and reply shapes are the
/// contract in docs/ARCHITECTURE.md; the Dart side is lib/src/*.dart.
///
/// What happens underneath, per call:
///  - "faster_flutter/method": the standard codec decodes the call on the
///    platform (main) thread; a Uint8List arrives as FlutterStandardTypedData
///    (one copy). The handler runs there and the reply is encoded again.
///  - "faster_flutter/binary": FlutterBinaryCodec passes the NSData through, with
///    no decoding. The reply is 4 bytes.
///  - classify: the frame arrives like the method payload, then the work moves to
///    a serial background queue (site "background") and the reply is posted back
///    to the main thread. Site "platform" runs it right in the handler so the
///    jank demo can show what that costs. The same split as ChannelBridgePlugin.kt.
///
/// The model runs in the TensorFlow Lite C runtime that flutter_litert links; see
/// TfLiteRuntime.swift and the README for why this plugin does not bring its own.
public final class ChannelBridgePlugin: NSObject, FlutterPlugin {
  static let methodChannelName = "faster_flutter/method"
  static let binaryChannelName = "faster_flutter/binary"
  private static let defaultThreads = 4

  private let registrar: FlutterPluginRegistrar

  /// One serial queue for loading and for background classification. Because both run
  /// here, a load never overlaps a classify that is already running on this queue.
  private let worker = DispatchQueue(label: "channel_bridge.classify")

  // Written by loadModel (on `worker`), read by classify (main thread). The lock makes
  // the hand-off safe. A classifier that is replaced while a call still uses it stays
  // alive until that call returns, because the call holds a reference.
  private let stateLock = NSLock()
  private var classifier: Classifier?
  private var runtime: TfLiteAPI?

  /// Owns the EventChannel for streamed llama.cpp tokens.
  let llama = LlamaChannel()

  init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    super.init()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let messenger = registrar.messenger()

    let method = FlutterMethodChannel(name: methodChannelName, binaryMessenger: messenger)
    let plugin = ChannelBridgePlugin(registrar: registrar)
    registrar.addMethodCallDelegate(plugin, channel: method)

    let binary = FlutterBasicMessageChannel(
      name: binaryChannelName,
      binaryMessenger: messenger,
      codec: FlutterBinaryCodec.sharedInstance())
    binary.setMessageHandler { message, reply in
      var sum: UInt32 = 0
      if let data = message as? Data {
        sum = byteSum(data)
      }
      // 4 bytes, little-endian, the same layout the Dart side reads.
      var littleEndian = sum.littleEndian
      reply(Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size))
    }

    plugin.llama.register(with: messenger)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "roundTrip":
      guard let typed = call.arguments as? FlutterStandardTypedData else {
        result(FlutterError(code: "bad_arguments", message: "roundTrip expects a Uint8List", details: nil))
        return
      }
      result(Int(byteSum(typed.data)))
    case "loadModel":
      loadModel(call, result: result)
    case "classify":
      classify(call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: loadModel

  private func loadModel(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let modelKey = args["model"] as? String,
      let labelsKey = args["labels"] as? String
    else {
      result(FlutterError(code: "bad_arguments", message: "loadModel expects {model, labels, threads}", details: nil))
      return
    }
    let threads = (args["threads"] as? Int) ?? ChannelBridgePlugin.defaultThreads
    guard let modelPath = assetPath(modelKey), let labelsPath = assetPath(labelsKey) else {
      result(FlutterError(code: "load_failed", message: "asset not found: \(modelKey) or \(labelsKey)", details: nil))
      return
    }

    // Load on the worker queue: the model file is 17 MB.
    worker.async {
      let outcome = Result<Void, Error> {
        let runtime = try self.loadedRuntime()
        let model = try Data(contentsOf: URL(fileURLWithPath: modelPath), options: .mappedIfSafe)
        let labels = parseLabels(try String(contentsOfFile: labelsPath, encoding: .utf8))
        let next = try model.withUnsafeBytes {
          try Classifier(api: runtime, modelBytes: $0, labels: labels, threads: threads)
        }
        self.stateLock.lock()
        self.classifier = next  // the previous one is freed when its last user lets go
        self.stateLock.unlock()
      }
      DispatchQueue.main.async {
        switch outcome {
        case .success: result(nil)
        case .failure(let error): result(ChannelBridgePlugin.flutterError(error, defaultCode: "load_failed"))
        }
      }
    }
  }

  /// Resolves the TFLite C symbols once. Runs on `worker`.
  private func loadedRuntime() throws -> TfLiteAPI {
    stateLock.lock()
    defer { stateLock.unlock() }
    if let runtime { return runtime }
    let resolved = try TfLiteAPI()
    runtime = resolved
    return resolved
  }

  /// The file system path of a Flutter asset inside the app bundle.
  private func assetPath(_ assetKey: String) -> String? {
    let key = registrar.lookupKey(forAsset: assetKey)
    if let path = Bundle.main.path(forResource: key, ofType: nil) { return path }
    let candidate = URL(fileURLWithPath: Bundle.main.bundlePath).appendingPathComponent(key).path
    return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
  }

  // MARK: classify

  private func classify(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let typed = args["rgba"] as? FlutterStandardTypedData,
      let width = args["width"] as? Int,
      let height = args["height"] as? Int
    else {
      result(FlutterError(code: "bad_arguments", message: "classify expects {rgba, width, height}", details: nil))
      return
    }
    let onPlatformThread = (args["site"] as? String) == "platform"

    stateLock.lock()
    let current = classifier
    stateLock.unlock()
    guard let current else {
      result(FlutterError(code: "not_loaded", message: "call loadModel first", details: nil))
      return
    }

    let frame = typed.data
    let compute: () -> Result<ClassifyResult, Error> = {
      Result {
        try frame.withUnsafeBytes {
          try current.classify(rgba: $0.bindMemory(to: UInt8.self), width: width, height: height)
        }
      }
    }

    if onPlatformThread {
      // Blocks the platform thread, and with merged threads the UI thread, until done.
      ChannelBridgePlugin.deliver(result, compute())
      return
    }
    worker.async {
      // Compute here, then answer on the main thread, where the call arrived.
      let outcome = compute()
      DispatchQueue.main.async { ChannelBridgePlugin.deliver(result, outcome) }
    }
  }

  private static func deliver(_ result: FlutterResult, _ outcome: Result<ClassifyResult, Error>) {
    switch outcome {
    case .success(let value):
      result([
        "index": value.index,
        "label": value.label,
        "confidence": value.confidence,
        "preprocessUs": value.preprocessMicros,
        "inferenceUs": value.inferenceMicros,
      ] as [String: Any])
    case .failure(let error):
      result(flutterError(error, defaultCode: "classify_failed"))
    }
  }

  private static func flutterError(_ error: Error, defaultCode: String) -> FlutterError {
    if let bridge = error as? BridgeError {
      return FlutterError(code: bridge.code, message: bridge.message, details: nil)
    }
    if let preprocess = error as? PreprocessError {
      return FlutterError(code: defaultCode, message: preprocess.description, details: nil)
    }
    return FlutterError(code: defaultCode, message: error.localizedDescription, details: nil)
  }
}

/// `ffb_checksum` from packages/ffi_bridge/src/ffi_bridge.c, the same C
/// function the FFI bridges call, so a race measures only the bridge and never
/// Swift against C. The ffi_bridge build hook ships it as
/// Frameworks/ffi_bridge.framework; Dart loads that framework on first use, so
/// if the channel runs first, load it here.
private typealias CChecksum = @convention(c) (UnsafePointer<UInt8>?, Int) -> UInt32
private let cChecksum: CChecksum? = {
  if processSymbolLookup("ffb_checksum") == nil, let dir = Bundle.main.privateFrameworksPath {
    _ = dlopen(dir + "/ffi_bridge.framework/ffi_bridge", RTLD_NOW | RTLD_GLOBAL)
  }
  guard let symbol = processSymbolLookup("ffb_checksum") else {
    NSLog("channel_bridge: ffb_checksum not found, using the Swift sum (the race is then not like for like)")
    return nil
  }
  return unsafeBitCast(symbol, to: CChecksum.self)
}()

/// The byte sum modulo 2^32, computed by `ffb_checksum` in C. The Swift loop
/// is only a fallback; `&+` wraps on overflow, which is exactly the modulo.
func byteSum(_ data: Data) -> UInt32 {
  data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> UInt32 in
    if let sum = cChecksum {
      return sum(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
    }
    var total: UInt32 = 0
    for byte in bytes {
      total = total &+ UInt32(byte)
    }
    return total
  }
}
