// The C preprocessor from packages/ffi_bridge, behind the Preprocessor
// interface, so the benchmark can race it against DartPreprocessor on the same
// frame with the same half-pixel bilinear rule.

import 'dart:typed_data';

import 'package:ffi_bridge/ffi_bridge.dart';

import 'bridge.dart';

class NativePreprocessorAdapter implements Preprocessor {
  final NativePreprocessor _native = NativePreprocessor();

  @override
  String get label => 'C via FFI';

  @override
  Float32List preprocess(Frame frame, {int size = 224}) =>
      _native.preprocess(frame.rgba, frame.width, frame.height, size: size);

  /// Writes straight into [out] (a tensor's native buffer, for example).
  void preprocessInto(Frame frame, Float32List out, {int size = 224}) => _native
      .preprocessInto(frame.rgba, frame.width, frame.height, out, size: size);

  void dispose() => _native.dispose();
}
