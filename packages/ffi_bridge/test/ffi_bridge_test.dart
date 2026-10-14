import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi_bridge/ffi_bridge.dart';
import 'package:test/test.dart';

/// The reference checksum: byte sum modulo 2^32 (same as the app's contract).
int referenceChecksum(Uint8List bytes) {
  var sum = 0;
  for (final b in bytes) {
    sum = (sum + b) & 0xFFFFFFFF;
  }
  return sum;
}

Uint8List randomBytes(int length, {int seed = 42}) {
  final random = Random(seed);
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = random.nextInt(256);
  }
  return bytes;
}

/// Plain Dart bilinear resize + scale to [-1, 1], written independently of
/// the C code (doubles, same pixel-centre convention).
Float32List referencePreprocess(Uint8List rgba, int w, int h, int size) {
  final out = Float32List(size * size * 3);
  int px(int x, int y, int c) => rgba[(y * w + x) * 4 + c];
  for (var y = 0; y < size; y++) {
    final fy = max(0.0, (y + 0.5) * h / size - 0.5);
    final y0 = min(fy.floor(), h - 1);
    final y1 = min(y0 + 1, h - 1);
    final wy = fy - y0;
    for (var x = 0; x < size; x++) {
      final fx = max(0.0, (x + 0.5) * w / size - 0.5);
      final x0 = min(fx.floor(), w - 1);
      final x1 = min(x0 + 1, w - 1);
      final wx = fx - x0;
      for (var c = 0; c < 3; c++) {
        final top = px(x0, y0, c) * (1 - wx) + px(x1, y0, c) * wx;
        final bottom = px(x0, y1, c) * (1 - wx) + px(x1, y1, c) * wx;
        final v = top * (1 - wy) + bottom * wy;
        out[(y * size + x) * 3 + c] = (v / 127.5 - 1).clamp(-1.0, 1.0);
      }
    }
  }
  return out;
}

void expectClose(
  Float32List actual,
  Float32List expected, {
  double tol = 1e-4,
}) {
  expect(actual.length, expected.length);
  var worst = 0.0;
  for (var i = 0; i < actual.length; i++) {
    worst = max(worst, (actual[i] - expected[i]).abs());
  }
  expect(worst, lessThan(tol), reason: 'largest difference was $worst');
}

void main() {
  group('FfiPayloadBridge checksum', () {
    final sizes = [0, 1, 1024, 8 * 1024 * 1024];
    final payloads = {for (final s in sizes) s: randomBytes(s, seed: s + 1)};

    for (final mode in FfiPayloadMode.values) {
      group(mode.name, () {
        late FfiPayloadBridge bridge;
        setUp(() async {
          bridge = FfiPayloadBridge(mode);
          await bridge.warmUp(8 * 1024 * 1024);
        });
        tearDown(() => bridge.dispose());

        for (final size in sizes) {
          test('$size bytes equals the Dart reference', () {
            final payload = payloads[size]!;
            final expected = referenceChecksum(payload);
            if (mode == FfiPayloadMode.zeroCopy) {
              bridge.nativeView.setAll(0, payload);
              expect(
                bridge.roundTrip(bridge.nativeView.sublist(0, size)),
                expected,
              );
              expect(bridge.roundTripNative(size), expected);
            } else {
              expect(bridge.roundTrip(payload), expected);
            }
          });
        }

        test('repeated calls give the same answer', () {
          final payload = payloads[1024]!;
          if (mode == FfiPayloadMode.zeroCopy) {
            bridge.nativeView.setAll(0, payload);
          }
          final first = bridge.roundTrip(payload);
          for (var i = 0; i < 50; i++) {
            expect(bridge.roundTrip(payload), first);
          }
        });
      });
    }

    test('checksum wraps modulo 2^32', () async {
      // 0xFF * 16843010 > 2^32, so the sum must wrap.
      final bytes = Uint8List(16843010)..fillRange(0, 16843010, 0xFF);
      final bridge = FfiPayloadBridge(FfiPayloadMode.leaf);
      expect(bridge.roundTrip(bytes), referenceChecksum(bytes));
      expect(referenceChecksum(bytes), lessThan(0x100000000));
      bridge.dispose();
    });

    test('copy mode needs warmUp and respects capacity', () async {
      final bridge = FfiPayloadBridge(FfiPayloadMode.copy);
      expect(() => bridge.roundTrip(Uint8List(4)), throwsStateError);
      await bridge.warmUp(8);
      expect(bridge.capacity, 8);
      expect(() => bridge.roundTrip(Uint8List(9)), throwsRangeError);
      expect(bridge.roundTrip(Uint8List.fromList([1, 2, 3])), 6);
      bridge.dispose();
    });

    test('nativeView only exists in zeroCopy mode', () async {
      final bridge = FfiPayloadBridge(FfiPayloadMode.copy);
      await bridge.warmUp(8);
      expect(() => bridge.nativeView, throwsStateError);
      bridge.dispose();
    });

    test('dispose is safe twice and blocks further use', () async {
      final bridge = FfiPayloadBridge(FfiPayloadMode.zeroCopy);
      await bridge.warmUp(16);
      bridge.dispose();
      bridge.dispose();
      expect(() => bridge.roundTripNative(1), throwsStateError);
    });

    test('warmUp can grow the buffer', () async {
      final bridge = FfiPayloadBridge(FfiPayloadMode.copy);
      await bridge.warmUp(4);
      await bridge.warmUp(1024);
      expect(bridge.capacity, 1024);
      final payload = randomBytes(1024);
      expect(bridge.roundTrip(payload), referenceChecksum(payload));
      bridge.dispose();
    });
  });

  group('NativePreprocessor', () {
    late NativePreprocessor pre;
    setUp(() => pre = NativePreprocessor());
    tearDown(() => pre.dispose());

    test('output shape and range for a 224 x 224 result', () {
      final rgba = randomBytes(640 * 480 * 4, seed: 7);
      // Force the extremes into the data so the range check means something.
      rgba[0] = 0;
      rgba[1] = 255;
      final out = pre.preprocess(rgba, 640, 480);
      expect(out.length, 224 * 224 * 3);
      for (final v in out) {
        expect(v, inInclusiveRange(-1.0, 1.0));
      }
    });

    test('same size is an exact rescale of every pixel', () {
      // 2 x 2 -> 2 x 2 touches no interpolation: out = value / 127.5 - 1.
      final rgba = Uint8List.fromList([
        255, 0, 0, 255, //
        0, 255, 0, 255, //
        0, 0, 255, 255, //
        128, 64, 32, 7, // alpha is ignored
      ]);
      final out = pre.preprocess(rgba, 2, 2, size: 2);
      expect(out.length, 12);
      final expected = [
        1.0, -1.0, -1.0, //
        -1.0, 1.0, -1.0, //
        -1.0, -1.0, 1.0, //
        128 / 127.5 - 1, 64 / 127.5 - 1, 32 / 127.5 - 1,
      ];
      for (var i = 0; i < expected.length; i++) {
        expect(out[i], closeTo(expected[i], 1e-6), reason: 'element $i');
      }
    });

    test('a known pixel in a 4 x 4 -> 2 x 2 downscale', () {
      // Top-left output pixel samples at (0.5, 0.5) in source space, which is
      // the average of the 2 x 2 block at the top-left.
      final rgba = Uint8List(4 * 4 * 4);
      for (var i = 0; i < 16; i++) {
        rgba[i * 4] = i * 10; // red ramp
        rgba[i * 4 + 1] = 100;
        rgba[i * 4 + 2] = 200;
        rgba[i * 4 + 3] = 255;
      }
      final out = pre.preprocess(rgba, 4, 4, size: 2);
      final meanRed = (0 + 10 + 40 + 50) / 4;
      expect(out[0], closeTo(meanRed / 127.5 - 1, 1e-6));
      expect(out[1], closeTo(100 / 127.5 - 1, 1e-6));
      expect(out[2], closeTo(200 / 127.5 - 1, 1e-6));
    });

    test('matches the Dart reference on several sizes', () {
      for (final (w, h, size) in [
        (640, 480, 224),
        (1920, 1080, 224),
        (3, 3, 7),
        (5, 9, 4),
        (1, 1, 3),
      ]) {
        final rgba = randomBytes(w * h * 4, seed: w * 31 + h);
        expectClose(
          pre.preprocess(rgba, w, h, size: size),
          referencePreprocess(rgba, w, h, size),
        );
      }
    });

    test('the result is a copy the caller owns', () {
      final a = randomBytes(8 * 8 * 4, seed: 1);
      final b = randomBytes(8 * 8 * 4, seed: 2);
      final first = pre.preprocess(a, 8, 8, size: 4);
      final snapshot = Float32List.fromList(first);
      pre.preprocess(b, 8, 8, size: 4);
      expect(first, snapshot);
    });

    test('buffers grow and shrink correctly between calls', () {
      final small = randomBytes(4 * 4 * 4, seed: 3);
      final big = randomBytes(64 * 64 * 4, seed: 4);
      expectClose(
        pre.preprocess(small, 4, 4, size: 8),
        referencePreprocess(small, 4, 4, 8),
      );
      expectClose(
        pre.preprocess(big, 64, 64, size: 16),
        referencePreprocess(big, 64, 64, 16),
      );
      expectClose(
        pre.preprocess(small, 4, 4, size: 8),
        referencePreprocess(small, 4, 4, 8),
      );
    });

    test('preprocessInto writes into native-backed and plain lists', () {
      final rgba = randomBytes(32 * 32 * 4, seed: 5);
      final expected = referencePreprocess(rgba, 32, 32, 16);

      final native = pre.allocateOutput(size: 16);
      expect(native.length, 16 * 16 * 3);
      pre.preprocessInto(rgba, 32, 32, native, size: 16);
      expectClose(native, expected);

      final plain = Float32List(16 * 16 * 3);
      pre.preprocessInto(rgba, 32, 32, plain, size: 16);
      expectClose(plain, expected);
    });

    test('bad arguments throw', () {
      expect(() => pre.preprocess(Uint8List(4), 2, 2), throwsArgumentError);
      expect(() => pre.preprocess(Uint8List(16), 0, 2), throwsArgumentError);
      expect(
        () => pre.preprocessInto(Uint8List(16), 2, 2, Float32List(3), size: 2),
        throwsArgumentError,
      );
    });

    test('dispose is safe twice and blocks further use', () {
      pre.dispose();
      pre.dispose();
      expect(
        () => pre.preprocess(Uint8List(16), 2, 2, size: 2),
        throwsStateError,
      );
    });
  });

  group('DemoTokenGenerator', () {
    late DemoTokenGenerator gen;
    setUp(() => gen = DemoTokenGenerator());
    tearDown(() => gen.dispose());

    const fast = Duration.zero;

    test(
      'emits tokens in order, each with its trailing space, then ends',
      () async {
        final tokens = await gen
            .generate('hello', maxTokens: 10, delay: fast)
            .toList();
        expect(tokens, hasLength(10));
        expect(tokens.take(3), ['On-device ', 'AI ', 'runs ']);
        expect(
          tokens.every((t) => t.endsWith(' ') && t.trim().isNotEmpty),
          isTrue,
        );
        expect(gen.isGenerating, isFalse);
      },
    );

    test('the text does not depend on the prompt', () async {
      final a = await gen.generate('one', maxTokens: 20, delay: fast).toList();
      final b = await gen.generate('two', maxTokens: 20, delay: fast).toList();
      expect(a, b);
    });

    test(
      'respects maxTokens, including 0 and counts past the text length',
      () async {
        for (final n in [0, 1, 5, 128, 400]) {
          final tokens = await gen
              .generate('x', maxTokens: n, delay: fast)
              .toList();
          expect(tokens, hasLength(n), reason: 'maxTokens=$n');
        }
      },
    );

    test('long runs repeat the text from the start', () async {
      final tokens = await gen
          .generate('x', maxTokens: 600, delay: fast)
          .toList();
      final period = tokens.indexOf('On-device ', 1);
      expect(period, greaterThan(100));
      expect(tokens[period + 2], tokens[2]);
    });

    test('delay spaces tokens out in time', () async {
      final watch = Stopwatch()..start();
      await gen
          .generate('x', maxTokens: 6, delay: const Duration(milliseconds: 20))
          .toList();
      // 5 gaps of 20 ms; allow generous slack on a busy machine.
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(80));
    });

    test('cancel stops the stream early and the stream closes', () async {
      final tokens = <String>[];
      final done = Completer<void>();
      late StreamSubscription<String> sub;
      sub = gen
          .generate(
            'x',
            maxTokens: 1000,
            delay: const Duration(milliseconds: 5),
          )
          .listen(tokens.add, onDone: done.complete);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await gen.cancel();
      await done.future.timeout(const Duration(seconds: 5));
      await sub.cancel();
      expect(tokens, isNotEmpty);
      expect(tokens.length, lessThan(1000));
      expect(gen.isGenerating, isFalse);
      final count = tokens.length;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(tokens.length, count, reason: 'no tokens after cancel');
    });

    test('cancelling the subscription cancels the native stream', () async {
      final sub = gen
          .generate(
            'x',
            maxTokens: 1000,
            delay: const Duration(milliseconds: 5),
          )
          .listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await sub.cancel();
      expect(gen.isGenerating, isFalse);
    });

    test('cancel with nothing running is a no-op', () async {
      await gen.cancel();
      await gen.generate('x', maxTokens: 2, delay: fast).toList();
      await gen.cancel();
    });

    test('a second generation can follow a cancelled one', () async {
      final sub = gen
          .generate(
            'x',
            maxTokens: 1000,
            delay: const Duration(milliseconds: 5),
          )
          .listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await gen.cancel();
      await sub.cancel();
      final tokens = await gen
          .generate('y', maxTokens: 4, delay: fast)
          .toList();
      expect(tokens, hasLength(4));
    });

    test('starting while one is running throws', () async {
      final stream = gen.generate(
        'x',
        maxTokens: 1000,
        delay: const Duration(milliseconds: 5),
      );
      expect(() => gen.generate('y'), throwsStateError);
      final sub = stream.listen((_) {});
      await gen.cancel();
      await sub.cancel();
    });

    test('dispose mid-stream ends the stream', () async {
      final done = Completer<void>();
      gen
          .generate(
            'x',
            maxTokens: 1000,
            delay: const Duration(milliseconds: 5),
          )
          .listen((_) {}, onDone: done.complete);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      gen.dispose();
      await done.future.timeout(const Duration(seconds: 5));
      expect(() => gen.generate('x'), throwsStateError);
    });
  });
}
