import 'dart:typed_data';

import 'package:faster_flutter/bridges/bridge.dart';
import 'package:faster_flutter/bridges/dart_preprocessor.dart';
import 'package:faster_flutter/bridges/fakes.dart';
import 'package:flutter_test/flutter_test.dart';

Frame _frame(int w, int h, int Function(int x, int y, int ch) pixel) {
  final rgba = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      for (var ch = 0; ch < 3; ch++) {
        rgba[i + ch] = pixel(x, y, ch);
      }
      rgba[i + 3] = 255;
    }
  }
  return Frame(rgba: rgba, width: w, height: h);
}

/// Straight from the spec in dart_preprocessor.dart, one pixel at a time and
/// without the column tables, to check the optimised version against.
Float32List _reference(Frame f, int size) {
  final out = Float32List(size * size * 3);
  double px(int x, int y, int ch) =>
      f.rgba[(y * f.width + x) * 4 + ch].toDouble();
  var o = 0;
  for (var dy = 0; dy < size; dy++) {
    for (var dx = 0; dx < size; dx++) {
      var sx = (dx + 0.5) * f.width / size - 0.5;
      var sy = (dy + 0.5) * f.height / size - 0.5;
      sx = sx.clamp(0, f.width - 1).toDouble();
      sy = sy.clamp(0, f.height - 1).toDouble();
      final x0 = sx.floor(), y0 = sy.floor();
      final x1 = x0 + 1 < f.width ? x0 + 1 : x0;
      final y1 = y0 + 1 < f.height ? y0 + 1 : y0;
      final fx = sx - x0, fy = sy - y0;
      for (var ch = 0; ch < 3; ch++) {
        final top = px(x0, y0, ch) * (1 - fx) + px(x1, y0, ch) * fx;
        final bottom = px(x0, y1, ch) * (1 - fx) + px(x1, y1, ch) * fx;
        out[o++] = (top * (1 - fy) + bottom * fy) / 127.5 - 1;
      }
    }
  }
  return out;
}

void main() {
  const pre = DartPreprocessor();

  test('label and output size', () {
    expect(pre.label, 'Dart');
    final out = pre.preprocess(makeFakeFrame(width: 40, height: 30), size: 16);
    expect(out, hasLength(16 * 16 * 3));
  });

  test('default size is 224', () {
    expect(pre.preprocess(makeFakeFrame()), hasLength(224 * 224 * 3));
  });

  test('uniform images give uniform output at the mapped value', () {
    for (final v in [0, 255, 128, 64]) {
      final out = pre.preprocess(_frame(37, 23, (x, y, ch) => v), size: 20);
      final expected = v / 127.5 - 1;
      expect(
        out.every((e) => (e - expected).abs() < 1e-6),
        isTrue,
        reason: 'v=$v',
      );
    }
    // 0 -> -1 and 255 -> +1 exactly.
    expect(pre.preprocess(_frame(4, 4, (x, y, ch) => 0), size: 2).first, -1.0);
    expect(pre.preprocess(_frame(4, 4, (x, y, ch) => 255), size: 2).first, 1.0);
  });

  test('channels stay in RGB order and alpha is dropped', () {
    final out = pre.preprocess(
      _frame(2, 2, (x, y, ch) => [0, 255, 51][ch]),
      size: 2,
    );
    expect(out[0], -1.0);
    expect(out[1], 1.0);
    expect(out[2], closeTo(51 / 127.5 - 1, 1e-6));
    expect(out, hasLength(12));
  });

  group('2x2 checkerboard', () {
    // (0,0) black, (1,0) white / (0,1) white, (1,1) black.
    final board = _frame(2, 2, (x, y, ch) => (x + y).isEven ? 0 : 255);

    test('same size reproduces the pixels exactly', () {
      final out = pre.preprocess(board, size: 2);
      expect([for (var i = 0; i < out.length; i += 3) out[i]], [-1, 1, 1, -1]);
    });

    test('upsampled to 4x4 follows the pixel-centre formula', () {
      // src = (dst + 0.5) * 0.5 - 0.5 -> -0.25 (clamped to 0), 0.25, 0.75, 1.25 (clamped to 1)
      final out = pre.preprocess(board, size: 4);
      double at(int x, int y) => out[(y * 4 + x) * 3];
      expect(at(0, 0), closeTo(-1.0, 1e-6)); // corner pixel
      expect(at(1, 0), closeTo(-0.5, 1e-6)); // 25% of the way to white
      expect(at(2, 0), closeTo(0.5, 1e-6)); // 75%
      expect(at(3, 0), closeTo(1.0, 1e-6)); // clamped to the white pixel
      expect(at(1, 1), closeTo(-0.25, 1e-6)); // both fractions 0.25
      expect(at(3, 3), closeTo(-1.0, 1e-6)); // clamped to the black pixel
      expect(at(0, 3), closeTo(1.0, 1e-6));
    });

    test('downsampled to 1x1 samples the centre: the mean', () {
      final out = pre.preprocess(board, size: 1);
      // src = 0.5 * 2 - 0.5 = 0.5 in both axes: average of the four pixels.
      expect(out[0], closeTo(0.0, 1e-6));
    });
  });

  test('matches a plain per-pixel reference on a non-square image', () {
    final f = makeFakeFrame(width: 61, height: 37, seed: 3);
    for (final size in [1, 7, 61, 100]) {
      final got = pre.preprocess(f, size: size);
      final want = _reference(f, size);
      for (var i = 0; i < got.length; i++) {
        expect(got[i], closeTo(want[i], 1e-5), reason: 'size $size index $i');
      }
    }
  });

  test('output stays inside [-1, 1]', () {
    final out = pre.preprocess(makeFakeFrame(seed: 5), size: 50);
    expect(out.every((v) => v >= -1 && v <= 1), isTrue);
  });

  test('bad input is rejected', () {
    expect(
      () => pre.preprocess(Frame(rgba: Uint8List(8), width: 4, height: 4)),
      throwsArgumentError,
    );
    expect(() => pre.preprocess(makeFakeFrame(), size: 0), throwsArgumentError);
  });
}
