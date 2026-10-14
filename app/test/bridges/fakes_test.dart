import 'dart:typed_data';

import 'package:faster_flutter/bridges/bridge.dart';
import 'package:faster_flutter/bridges/fakes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FakePayloadBridge', () {
    final payload = Uint8List.fromList([1, 2, 3, 250]);

    test('FFI kinds answer at once, channel kinds with a future', () async {
      final ffi = FakePayloadBridge(BridgeKind.ffiLeaf);
      final channel = FakePayloadBridge(BridgeKind.methodChannel);
      expect(ffi.roundTrip(payload), 256);
      final answer = channel.roundTrip(payload);
      expect(answer, isA<Future<int>>());
      expect(await answer, 256);
    });

    test('latency follows fixedMicros and perByteNanos', () {
      final bridge = FakePayloadBridge(
        BridgeKind.ffiCopy,
        fixedMicros: 300,
        perByteNanos: 1000, // 1 us per byte
      );
      final sw = Stopwatch()..start();
      bridge.roundTrip(Uint8List(200));
      expect(sw.elapsedMicroseconds, greaterThanOrEqualTo(500));
    });

    test('corruptChecksum makes every answer wrong', () {
      final bridge = FakePayloadBridge(
        BridgeKind.ffiCopy,
        corruptChecksum: true,
      );
      expect(bridge.roundTrip(payload), isNot(checksum(payload)));
    });

    test('warmUp and dispose are recorded, dispose twice is fine', () async {
      final bridge = FakePayloadBridge(BridgeKind.ffiZeroCopy);
      await bridge.warmUp(99);
      bridge.dispose();
      bridge.dispose();
      expect(bridge.warmedUpBytes, 99);
      expect(bridge.disposed, isTrue);
    });
  });

  group('FakeClassifier', () {
    test('is deterministic and splits the time', () async {
      final a = FakeClassifier()..loaded = true;
      final b = FakeClassifier()..loaded = true;
      final frame = makeFakeFrame();
      final ra = await a.classify(frame);
      final rb = await b.classify(frame);
      expect(ra.label, rb.label);
      expect(ra.confidence, rb.confidence);
      expect(ra.totalMicros, rb.totalMicros);
      expect(ra.bridgeMicros, 150);
      expect(ra.confidence, inInclusiveRange(0.5, 1.0));
      expect(ra.labelIndex, lessThan(a.labels.length));
    });

    test('different frames can give different labels', () async {
      final c = FakeClassifier();
      await c.load();
      final labels = {
        for (var s = 0; s < 12; s++)
          (await c.classify(makeFakeFrame(seed: s))).label,
      };
      expect(labels.length, greaterThan(1));
    });

    test('classify before load is a StateError', () {
      expect(
        () => FakeClassifier().classify(makeFakeFrame()),
        throwsStateError,
      );
    });
  });

  group('FakeTokenGenerator', () {
    test(
      'streams maxTokens tokens, the same ones for the same prompt',
      () async {
        final g = FakeTokenGenerator(tokenDelay: Duration.zero);
        await g.load();
        final first = await g.generate('hi', maxTokens: 6).toList();
        final second = await g.generate('hi', maxTokens: 6).toList();
        expect(first, hasLength(6));
        expect(second, first);
        final other = await g
            .generate('a different prompt', maxTokens: 6)
            .toList();
        expect(other, isNot(first));
      },
    );

    test('cancel ends the stream early', () async {
      final g = FakeTokenGenerator(tokenDelay: const Duration(milliseconds: 1));
      await g.load();
      var count = 0;
      await for (final _ in g.generate('x', maxTokens: 1000)) {
        if (++count == 3) await g.cancel();
      }
      expect(count, lessThan(10));
    });

    test('flags and label', () {
      final g = FakeTokenGenerator(isRealModel: true, label: 'LLM');
      expect(g.isRealModel, isTrue);
      expect(g.label, 'LLM');
    });
  });
}
