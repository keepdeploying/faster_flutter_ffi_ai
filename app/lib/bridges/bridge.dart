// The contracts every bridge implements. The app, the benchmark runner and the
// tests depend only on these types, never on a concrete bridge, so a slide can
// say "same model, same input, only the bridge differs" and mean it.

import 'dart:async';
import 'dart:typed_data';

/// How a call gets from Dart to native code.
///
/// The order is the order of the talk: from the most work per call to the least.
enum BridgeKind {
  /// `MethodChannel` with `StandardMessageCodec`: encode, copy, hop threads.
  methodChannel('MethodChannel', isFfi: false),

  /// `BasicMessageChannel` with `BinaryCodec`: the fastest channel setup the
  /// Flutter team recommends (Flutter blog, 2021). Still copies and hops.
  binaryChannel('BinaryCodec channel', isFfi: false),

  /// `dart:ffi` with a malloc'd native buffer the payload is copied into.
  ffiCopy('FFI + copy', isFfi: true),

  /// `@Native(isLeaf: true)` receiving the `Uint8List` itself (`.address`).
  /// No copy, no VM transition, but must be short and never call back.
  ffiLeaf('FFI leaf', isFfi: true),

  /// The payload already lives in native memory (`asTypedList` view), so the
  /// call passes only a pointer.
  ffiZeroCopy('FFI zero-copy', isFfi: true);

  const BridgeKind(this.label, {required this.isFfi});

  final String label;
  final bool isFfi;
}

/// Moves bytes across the bridge and back.
///
/// The native side reads every byte and returns [checksum] of them, so no
/// compiler can skip the work and every call is verified.
abstract interface class PayloadBridge {
  BridgeKind get kind;

  /// Prepares any reusable buffers for payloads up to [maxBytes].
  Future<void> warmUp(int maxBytes);

  /// One round trip. Returns the checksum computed natively.
  FutureOr<int> roundTrip(Uint8List payload);

  /// Frees native memory. Safe to call twice.
  void dispose();
}

/// The reference checksum both sides compute: the byte sum, modulo 2^32.
int checksum(Uint8List bytes) {
  var sum = 0;
  for (final b in bytes) {
    sum = (sum + b) & 0xFFFFFFFF;
  }
  return sum;
}

/// A camera-like frame: tightly packed RGBA8888, row after row.
class Frame {
  const Frame({required this.rgba, required this.width, required this.height});

  final Uint8List rgba;
  final int width;
  final int height;
}

/// Turns a [Frame] into the model input: [size] x [size] x 3 floats in [-1, 1],
/// bilinear resize, row-major, RGB order.
abstract interface class Preprocessor {
  String get label;
  Float32List preprocess(Frame frame, {int size = 224});
}

/// One classification with its time split, measured on the native side where
/// possible, so the bridge share can be shown on a slide.
class Classification {
  const Classification({
    required this.labelIndex,
    required this.label,
    required this.confidence,
    required this.totalMicros,
    required this.preprocessMicros,
    required this.inferenceMicros,
  });

  final int labelIndex;
  final String label;
  final double confidence;

  /// Wall time seen by Dart, from the call to the result.
  final int totalMicros;

  /// Time spent turning the frame into a tensor.
  final int preprocessMicros;

  /// Time spent inside the model runtime (LiteRT `invoke`).
  final int inferenceMicros;

  /// Everything that is neither preprocessing nor inference: the bridge.
  int get bridgeMicros => totalMicros - preprocessMicros - inferenceMicros;
}

/// Classifies frames with the same .tflite model on both paths.
abstract interface class Classifier {
  BridgeKind get kind;
  Future<void> load();
  Future<Classification> classify(Frame frame);
  void dispose();
}

/// Where the work of a classifier runs. On merged threads (Flutter 3.29+ on
/// mobile), [uiThread] blocks frames for as long as the call takes.
enum ExecutionSite { uiThread, isolate, nativeThread }

/// Streams generated text token by token.
abstract interface class TokenGenerator {
  String get label;

  /// True for a real model; false for the C demo generator.
  bool get isRealModel;
  Future<void> load();
  Stream<String> generate(String prompt, {int maxTokens = 128});
  Future<void> cancel();
  void dispose();
}
