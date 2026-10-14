// Preprocessing in plain Dart: the "before" half of the preprocessing slide.
// `NativePreprocessor` (C through FFI) does the same arithmetic; a test and a
// slide can put the two outputs side by side.
//
// The spec both versions follow (this is the one place it is written down):
//
//   scale_x = width / size          scale_y = height / size
//   src_x   = (dst_x + 0.5) * scale_x - 0.5      (pixel-centre alignment)
//   src_y   = (dst_y + 0.5) * scale_y - 0.5
//   src is clamped to [0, width - 1] and [0, height - 1] (edge pixels repeat)
//   x0 = floor(src_x), x1 = min(x0 + 1, width - 1), fx = src_x - x0   (same for y)
//   value = lerp(lerp(p00, p10, fx), lerp(p01, p11, fx), fy)   per channel, 0..255
//   out   = value / 127.5 - 1                                  -> [-1, 1]
//
// Output is row-major, RGB order (alpha is dropped), `size * size * 3` floats.
// The maths runs in double and is stored as float32; a C version that works in
// float can differ by a few 1e-7.

import 'dart:typed_data';

import 'bridge.dart';

class DartPreprocessor implements Preprocessor {
  const DartPreprocessor();

  @override
  String get label => 'Dart';

  @override
  Float32List preprocess(Frame frame, {int size = 224}) {
    final w = frame.width;
    final h = frame.height;
    if (size <= 0) {
      throw ArgumentError.value(size, 'size', 'must be positive');
    }
    if (w <= 0 || h <= 0) {
      throw ArgumentError('Frame size must be positive, got ${w}x$h');
    }
    final rgba = frame.rgba;
    if (rgba.length < w * h * 4) {
      throw ArgumentError(
        'rgba has ${rgba.length} bytes, a ${w}x$h frame needs ${w * h * 4}',
      );
    }

    final scaleX = w / size;
    final scaleY = h / size;

    // The column work is the same for every row, so it is done once. The rows
    // below only look the numbers up.
    final x0s = Int32List(size);
    final x1s = Int32List(size);
    final fxs = Float64List(size);
    for (var dx = 0; dx < size; dx++) {
      final sx = _clamp((dx + 0.5) * scaleX - 0.5, w - 1);
      final x0 = sx.floor();
      x0s[dx] = x0 * 4;
      x1s[dx] = (x0 + 1 < w ? x0 + 1 : w - 1) * 4;
      fxs[dx] = sx - x0;
    }

    final out = Float32List(size * size * 3);
    final rowStride = w * 4;
    var o = 0;
    for (var dy = 0; dy < size; dy++) {
      final sy = _clamp((dy + 0.5) * scaleY - 0.5, h - 1);
      final y0 = sy.floor();
      final y1 = y0 + 1 < h ? y0 + 1 : h - 1;
      final fy = sy - y0;
      final row0 = y0 * rowStride;
      final row1 = y1 * rowStride;
      for (var dx = 0; dx < size; dx++) {
        final a = row0 + x0s[dx];
        final b = row0 + x1s[dx];
        final c = row1 + x0s[dx];
        final d = row1 + x1s[dx];
        final fx = fxs[dx];
        for (var ch = 0; ch < 3; ch++) {
          final top = rgba[a + ch] + (rgba[b + ch] - rgba[a + ch]) * fx;
          final bottom = rgba[c + ch] + (rgba[d + ch] - rgba[c + ch]) * fx;
          final value = top + (bottom - top) * fy;
          out[o++] = value / 127.5 - 1.0;
        }
      }
    }
    return out;
  }

  static double _clamp(double v, int max) =>
      v < 0 ? 0.0 : (v > max ? max.toDouble() : v);
}
