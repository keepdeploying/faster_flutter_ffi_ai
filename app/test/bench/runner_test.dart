import 'dart:async';

import 'package:faster_flutter/bench/frame_meter.dart';
import 'package:faster_flutter/bench/runner.dart';
import 'package:faster_flutter/bridges/bridge.dart';
import 'package:faster_flutter/bridges/dart_preprocessor.dart';
import 'package:faster_flutter/bridges/fakes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BenchmarkRunner runner;
  setUp(() => runner = BenchmarkRunner());
  tearDown(() => runner.dispose());

  group('roundTrip', () {
    test('measures a fake bridge and reports its fixed latency', () async {
      final bridge = FakePayloadBridge(BridgeKind.ffiLeaf, fixedMicros: 200);
      final r = await runner.roundTrip(
        bridge,
        payloadBytes: 1024,
        warmup: 3,
        runs: 20,
      );
      expect(r.bridge, 'ffiLeaf');
      expect(r.payloadBytes, 1024);
      expect(r.warmup, 3);
      expect(r.runs, 20);
      expect(r.stats.count, 20);
      expect(r.stats.p50Us, greaterThanOrEqualTo(200));
      expect(r.stats.minUs, greaterThanOrEqualTo(200));
      expect(bridge.calls, 23);
      expect(bridge.warmedUpBytes, 1024);
    });

    test('channel-style (async) bridges work too', () async {
      final bridge = FakePayloadBridge(
        BridgeKind.binaryChannel,
        fixedMicros: 50,
      );
      final r = await runner.roundTrip(
        bridge,
        payloadBytes: 0,
        warmup: 1,
        runs: 5,
      );
      expect(r.bridge, 'binaryChannel');
      expect(r.stats.count, 5);
    });

    test('a checksum mismatch throws, sync and async', () async {
      for (final kind in [BridgeKind.ffiCopy, BridgeKind.methodChannel]) {
        final bad = FakePayloadBridge(kind, corruptChecksum: true);
        await expectLater(
          runner.roundTrip(bad, payloadBytes: 64, warmup: 0, runs: 5),
          throwsA(isA<ChecksumMismatch>()),
        );
      }
    });

    test('a mismatch during warm-up throws as well', () async {
      final bad = FakePayloadBridge(BridgeKind.ffiCopy, corruptChecksum: true);
      await expectLater(
        runner.roundTrip(bad, payloadBytes: 64, warmup: 2, runs: 0),
        throwsA(isA<ChecksumMismatch>()),
      );
    });

    test('repeats keeps the repeat with the median p50', () async {
      // Latency per call is 100, 400, 200 us across the three repeats.
      final bridge = _SteppedBridge([100, 400, 200], callsPerRepeat: 6);
      final r = await runner.roundTrip(
        bridge,
        payloadBytes: 16,
        warmup: 2,
        runs: 4,
        repeats: 3,
      );
      expect(r.stats.p50Us, greaterThanOrEqualTo(200));
      expect(r.stats.p50Us, lessThan(400));
    });

    test('reports progress and ends at 100 percent', () async {
      final events = <BenchProgress>[];
      final sub = runner.progress.listen(events.add);
      await runner.roundTrip(
        FakePayloadBridge(BridgeKind.ffiCopy),
        payloadBytes: 8,
        warmup: 1,
        runs: 10,
      );
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(events, isNotEmpty);
      expect(events.last.suite, 'round_trip');
      expect(events.last.isDone, isTrue);
      expect(events.last.fraction, 1.0);
    });

    test('cancel stops the suite', () async {
      final bridge = FakePayloadBridge(BridgeKind.ffiCopy, fixedMicros: 100);
      final future = runner.roundTrip(
        bridge,
        payloadBytes: 8,
        warmup: 0,
        runs: 100000,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      runner.cancel();
      await expectLater(future, throwsA(isA<BenchCancelled>()));
      expect(bridge.calls, lessThan(100000));
      // A cancelled runner refuses new work until reset.
      await expectLater(
        runner.roundTrip(bridge, payloadBytes: 8, warmup: 0, runs: 1),
        throwsA(isA<BenchCancelled>()),
      );
      runner.reset();
      final again = await runner.roundTrip(
        bridge,
        payloadBytes: 8,
        warmup: 0,
        runs: 1,
      );
      expect(again.runs, 1);
    });
  });

  group('preprocess', () {
    test('times the Dart preprocessor', () async {
      final r = await runner.preprocess(
        const DartPreprocessor(),
        makeFakeFrame(width: 32, height: 24),
        runs: 10,
        warmup: 2,
        size: 32,
        repeats: 2,
      );
      expect(r.impl, 'dart');
      expect(r.runs, 10);
      expect(r.stats.p50Us, greaterThan(0));
    });

    test('impl overrides the name', () async {
      final r = await runner.preprocess(
        const DartPreprocessor(),
        makeFakeFrame(),
        runs: 2,
        warmup: 0,
        size: 8,
        impl: 'c',
      );
      expect(r.impl, 'c');
    });
  });

  group('classify', () {
    test('splits total, preprocess, inference and bridge', () async {
      final c = FakeClassifier(
        kind: BridgeKind.ffiCopy,
        preprocessMicros: 300,
        inferenceMicros: 2000,
        bridgeMicros: 150,
      );
      await c.load();
      final r = await runner.classify(
        c,
        [makeFakeFrame(seed: 1), makeFakeFrame(seed: 2)],
        runs: 20,
        warmup: 2,
        site: ExecutionSite.isolate,
      );
      expect(r.bridge, 'ffiCopy');
      expect(r.site, 'isolate');
      expect(r.preprocess.p50Us, 300);
      expect(r.overhead.p50Us, 150);
      expect(r.inference.minUs, 2000);
      expect(r.total.p50Us, closeTo(300 + 150 + r.inference.p50Us, 1e-9));
    });

    test('needs at least one frame', () async {
      final c = FakeClassifier();
      await c.load();
      expect(() => runner.classify(c, []), throwsArgumentError);
    });
  });

  group('jank', () {
    test('counts the janky frames the meter saw during the run', () async {
      final meter = FrameMeter(budgetMs: 16.7);
      var i = 0;
      final r = await runner.jank(
        bridge: 'methodChannel',
        site: ExecutionSite.uiThread,
        duration: const Duration(milliseconds: 150),
        meter: meter,
        keepFramesFlowing: false,
        work: () => meter.recordFrameMs(i++ % 4 == 3 ? 40 : 8),
      );
      expect(r.bridge, 'methodChannel');
      expect(r.site, 'uiThread');
      expect(r.frames, greaterThan(3));
      expect(r.jankyFrames, r.frames ~/ 4);
      expect(r.worstFrameMs, 40);
      expect(r.budgetMs, 16.7);
      expect(r.seconds, closeTo(0.15, 1e-9));
      expect(meter.isRunning, isFalse);
      meter.dispose();
    });
  });

  group('generate', () {
    test('first token time, token rate and token count', () async {
      final g = FakeTokenGenerator(tokenDelay: const Duration(milliseconds: 5));
      await g.load();
      final r = await runner.generate(g, 'hello', maxTokens: 12);
      expect(r.generator, 'demo');
      expect(r.tokens, 12);
      expect(r.firstTokenMs, greaterThanOrEqualTo(4));
      // 5 ms per token is at most 200 tokens/s.
      expect(r.tokensPerSec, inInclusiveRange(20, 205));
      expect(r.jankyFrames, 0);
    });

    test(
      'a real-model flag is named llm and repeats still return one',
      () async {
        final g = FakeTokenGenerator(
          tokenDelay: const Duration(milliseconds: 1),
          isRealModel: true,
        );
        await g.load();
        final r = await runner.generate(g, 'x', maxTokens: 5, repeats: 3);
        expect(r.generator, 'llm');
        expect(r.tokens, 5);
      },
    );

    test('cancel cancels the generator and throws', () async {
      final g = FakeTokenGenerator(tokenDelay: const Duration(milliseconds: 2));
      await g.load();
      final future = runner.generate(g, 'x', maxTokens: 100000);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      runner.cancel();
      await expectLater(future, throwsA(isA<BenchCancelled>()));
    });
  });
}

/// Fake bridge whose latency changes every [callsPerRepeat] calls.
class _SteppedBridge implements PayloadBridge {
  _SteppedBridge(this.micros, {required this.callsPerRepeat});

  final List<double> micros;
  final int callsPerRepeat;
  int _n = 0;

  @override
  BridgeKind get kind => BridgeKind.ffiCopy;

  @override
  Future<void> warmUp(int maxBytes) async {}

  @override
  FutureOr<int> roundTrip(payload) {
    final us = micros[(_n++ ~/ callsPerRepeat).clamp(0, micros.length - 1)];
    final sw = Stopwatch()..start();
    while (sw.elapsedMicroseconds < us) {}
    return checksum(payload);
  }

  @override
  void dispose() {}
}
