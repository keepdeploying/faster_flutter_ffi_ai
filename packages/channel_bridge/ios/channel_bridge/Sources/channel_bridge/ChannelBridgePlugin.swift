import Flutter
import UIKit

/// The two Flutter channels of the demo. Names, methods and reply shapes are the
/// contract in docs/ARCHITECTURE.md; the Dart side is lib/src/*.dart.
///
/// What happens underneath, per call:
///  - "faster_flutter/method": the standard codec decodes the call on the
///    platform (main) thread; a Uint8List arrives as FlutterStandardTypedData
///    (one copy). The handler runs there and the reply is encoded again.
///  - "faster_flutter/binary": FlutterBinaryCodec passes the NSData through, with
///    no decoding. The reply is 4 bytes.
public final class ChannelBridgePlugin: NSObject, FlutterPlugin {
  static let methodChannelName = "faster_flutter/method"
  static let binaryChannelName = "faster_flutter/binary"

  public static func register(with registrar: FlutterPluginRegistrar) {
    let messenger = registrar.messenger()

    let method = FlutterMethodChannel(name: methodChannelName, binaryMessenger: messenger)
    registrar.addMethodCallDelegate(ChannelBridgePlugin(), channel: method)

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
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "roundTrip":
      guard let typed = call.arguments as? FlutterStandardTypedData else {
        result(FlutterError(code: "bad_arguments", message: "roundTrip expects a Uint8List", details: nil))
        return
      }
      result(Int(byteSum(typed.data)))
    case "loadModel", "classify":
      // TODO(classifier-ios): run the same MobileNet on iOS. What is missing is the
      // runtime. flutter_litert ships TensorFlowLiteC as a SwiftPM binary target
      // (a GitHub release xcframework) and the app already links it. This plugin
      // should not add a second copy: two binary targets with the same name
      // (TensorFlowLiteC) in one build are likely to be rejected by SwiftPM, and
      // two copies of the TensorFlow Lite symbols would clash at link time. This
      // could not be tried here: the Linux VM has no Swift toolchain.
      // Options: (a) call the C API (TfLiteModelCreate, TfLiteInterpreter*)
      // through dlsym on the copy flutter_litert already loaded, or (b) have the
      // host app pass in a runtime. Preprocessing is a direct port of
      // Preprocess.kt, and the timing code is DispatchTime.now().uptimeNanoseconds.
      result(
        FlutterError(
          code: "unsupported_on_ios",
          message: "The channel classifier is not implemented on iOS yet. See the TODO in ChannelBridgePlugin.swift.",
          details: nil))
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// The byte sum modulo 2^32, the same as `checksum()` in Dart and Kotlin.
/// `&+` wraps on overflow, which is exactly the modulo.
func byteSum(_ data: Data) -> UInt32 {
  var sum: UInt32 = 0
  data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
    for byte in bytes {
      sum = sum &+ UInt32(byte)
    }
  }
  return sum
}
