import Dispatch
import Flutter
import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// The llama.cpp side of the demo on iOS, reached over an EventChannel.
///
/// The `libllm_bridge` library is linked into the host process by the FFI path
/// (via `DynamicLibrary.process()` in Dart). This file reaches the same C ABI
/// through `dlsym(RTLD_DEFAULT, ...)`, mirroring the shape of
/// `TfLiteRuntime.swift` in this package. The subset of the ABI used is the
/// pull model added in llm_bridge.h: `llb_prompt_pull` starts a generation
/// whose tokens land in an internal queue, and `llb_pull_next_token` blocks
/// until the next token (or NULL at end of stream).
///
/// One model is cached per instance, keyed by modelPath. A new path frees the
/// old handle; the lock keeps a load and a running generation from racing.
final class LlamaChannel: NSObject, FlutterStreamHandler {
  static let channelName = "faster_flutter/llm"
  private static let errBufLen = 512

  /// Opaque model handle.
  typealias ModelHandle = OpaquePointer

  private struct LlamaAPI {
    let load: @convention(c) (
      UnsafePointer<CChar>?, Int32, Int32, UnsafeMutablePointer<CChar>?, Int32
    ) -> OpaquePointer?
    let unload: @convention(c) (OpaquePointer?) -> Void
    let promptPull: @convention(c) (
      OpaquePointer?, UnsafePointer<CChar>?, Int32, Float, UInt32
    ) -> Int64
    let pullNextToken: @convention(c) (Int64) -> UnsafePointer<CChar>?
    let cancel: @convention(c) (OpaquePointer?, Int64) -> Void
  }

  private var channel: FlutterEventChannel?
  private let worker = DispatchQueue(label: "channel_bridge.llama")

  // Guards the model cache and the active-stream handoff. All writes happen
  // under this lock.
  private let stateLock = NSLock()
  private var modelPath: String?
  private var modelHandle: OpaquePointer?
  private var activeStream: Int64 = 0
  private var activeHandle: OpaquePointer?

  private var api: LlamaAPI?

  func register(with messenger: FlutterBinaryMessenger) {
    let eventChannel = FlutterEventChannel(name: LlamaChannel.channelName, binaryMessenger: messenger)
    eventChannel.setStreamHandler(self)
    channel = eventChannel
  }

  func unregister() {
    channel?.setStreamHandler(nil)
    channel = nil
    stopActiveStream()
    stateLock.lock()
    let handle = modelHandle
    modelHandle = nil
    modelPath = nil
    let unload = api?.unload
    stateLock.unlock()
    if let handle, let unload { unload(handle) }
  }

  // MARK: FlutterStreamHandler

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    guard let args = arguments as? [String: Any],
      let path = args["modelPath"] as? String,
      let prompt = args["prompt"] as? String
    else {
      return FlutterError(code: "bad_arguments", message: "generate expects {modelPath, prompt}", details: nil)
    }
    let contextSize = (args["contextSize"] as? NSNumber)?.int32Value ?? 1024
    let threads = (args["threads"] as? NSNumber)?.int32Value ?? 4
    let maxTokens = (args["maxTokens"] as? NSNumber)?.int32Value ?? 128
    let temperature = (args["temperature"] as? NSNumber)?.floatValue ?? 0.0
    let seed = (args["seed"] as? NSNumber)?.uint32Value ?? 0

    worker.async { [weak self] in
      self?.runGeneration(
        path: path,
        contextSize: contextSize,
        threads: threads,
        prompt: prompt,
        maxTokens: maxTokens,
        temperature: temperature,
        seed: seed,
        events: events)
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    stopActiveStream()
    return nil
  }

  // MARK: internals

  private func stopActiveStream() {
    stateLock.lock()
    let stream = activeStream
    let handle = activeHandle
    let cancel = api?.cancel
    stateLock.unlock()
    if stream != 0, let handle, let cancel { cancel(handle, stream) }
  }

  private func runGeneration(
    path: String,
    contextSize: Int32,
    threads: Int32,
    prompt: String,
    maxTokens: Int32,
    temperature: Float,
    seed: UInt32,
    events: @escaping FlutterEventSink
  ) {
    let api: LlamaAPI
    do {
      api = try loadedApi()
    } catch {
      postError(events, code: "runtime_missing", message: (error as? BridgeError)?.message ?? error.localizedDescription)
      postEnd(events)
      return
    }

    let handle: OpaquePointer
    do {
      handle = try ensureModel(path: path, contextSize: contextSize, threads: threads, api: api)
    } catch {
      postError(events, code: "load_failed", message: (error as? BridgeError)?.message ?? error.localizedDescription)
      postEnd(events)
      return
    }

    let streamId = prompt.withCString { cstr in
      api.promptPull(handle, cstr, maxTokens, temperature, seed)
    }
    if streamId <= 0 {
      postError(events, code: "generate_failed", message: "llb_prompt_pull returned \(streamId)")
      postEnd(events)
      return
    }
    stateLock.lock()
    activeHandle = handle
    activeStream = streamId
    stateLock.unlock()

    while true {
      guard let ptr = api.pullNextToken(streamId) else { break }
      let token = String(cString: ptr)
      postToken(events, token: token)
    }

    stateLock.lock()
    activeHandle = nil
    activeStream = 0
    stateLock.unlock()
    postEnd(events)
  }

  private func ensureModel(path: String, contextSize: Int32, threads: Int32, api: LlamaAPI) throws -> OpaquePointer {
    stateLock.lock()
    if let handle = modelHandle, modelPath == path {
      stateLock.unlock()
      return handle
    }
    let previous = modelHandle
    modelHandle = nil
    modelPath = nil
    stateLock.unlock()
    if let previous { api.unload(previous) }

    var errBuf = [CChar](repeating: 0, count: Int(LlamaChannel.errBufLen))
    let handle: OpaquePointer? = path.withCString { cpath in
      errBuf.withUnsafeMutableBufferPointer { buf in
        api.load(cpath, contextSize, threads, buf.baseAddress, LlamaChannel.errBufLen)
      }
    }
    guard let handle else {
      let message = errBuf.withUnsafeBufferPointer { buf -> String in
        guard let base = buf.baseAddress else { return "" }
        return String(cString: base)
      }
      throw BridgeError(code: "load_failed", message: message.isEmpty ? "llb_load returned null" : message)
    }
    stateLock.lock()
    modelHandle = handle
    modelPath = path
    stateLock.unlock()
    return handle
  }

  private func loadedApi() throws -> LlamaAPI {
    stateLock.lock()
    if let cached = api {
      stateLock.unlock()
      return cached
    }
    stateLock.unlock()

    let names = [
      "llb_load", "llb_unload", "llb_prompt_pull", "llb_pull_next_token", "llb_cancel",
    ]
    let missing = names.filter { processSymbolLookup($0) == nil }
    guard missing.isEmpty else {
      throw BridgeError(
        code: "runtime_missing",
        message:
          "libllm_bridge is not loaded in this process (missing: "
          + missing.joined(separator: ", ")
          + "). The channel path shares the FFI build; make sure llm_bridge is a dependency.")
    }
    func symbol<T>(_ name: String) -> T {
      unsafeBitCast(processSymbolLookup(name)!, to: T.self)
    }
    let built = LlamaAPI(
      load: symbol("llb_load"),
      unload: symbol("llb_unload"),
      promptPull: symbol("llb_prompt_pull"),
      pullNextToken: symbol("llb_pull_next_token"),
      cancel: symbol("llb_cancel"))
    stateLock.lock()
    api = built
    stateLock.unlock()
    return built
  }

  private func postToken(_ events: @escaping FlutterEventSink, token: String) {
    DispatchQueue.main.async { events(token) }
  }

  private func postError(_ events: @escaping FlutterEventSink, code: String, message: String) {
    DispatchQueue.main.async { events(FlutterError(code: code, message: message, details: nil)) }
  }

  private func postEnd(_ events: @escaping FlutterEventSink) {
    DispatchQueue.main.async { events(FlutterEndOfEventStream) }
  }
}
