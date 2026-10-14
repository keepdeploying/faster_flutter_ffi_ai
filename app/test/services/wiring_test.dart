// Checks the wiring between the app and the native packages. The FFI tests run
// the real C code: `flutter test` builds packages/ffi_bridge through its build
// hook for the machine running the tests.

import 'dart:typed_data';

import 'package:faster_flutter/bench/frame_meter.dart';
import 'package:faster_flutter/bench/host.dart';
import 'package:faster_flutter/bridges/bridge.dart';
import 'package:faster_flutter/bridges/dart_preprocessor.dart';
import 'package:faster_flutter/bridges/fakes.dart';
import 'package:faster_flutter/bridges/native_preprocessor_adapter.dart';
import 'package:faster_flutter/bridges/payload_adapters.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _payload(int bytes, int seed) => Uint8List.fromList([
  for (var i = 0; i < bytes; i++) (i * 31 + seed) & 0xFF,
]);

class _MissingModel implements TokenGenerator {
  @override
  String get label => 'LLM';
  @override
  bool get isRealModel => true;
  @override
  Future<void> load() async => throw StateError('Model file not found.');
  @override
  Stream<String> generate(String prompt, {int maxTokens = 128}) =>
      const Stream.empty();
  @override
  Future<void> cancel() async {}
  @override
  void dispose() {}
}

void main() {
  group('FfiPayloadAdapter (real C)', () {
    for (final kind in BridgeKind.values.where((k) => k.isFfi)) {
      test('${kind.name} returns the Dart checksum', () async {
        final bridge = FfiPayloadAdapter(kind);
        await bridge.warmUp(65536);
        for (final bytes in [0, 1, 1024, 65536]) {
          final p = _payload(bytes, bytes);
          expect(bridge.roundTrip(p), checksum(p), reason: '$bytes bytes');
        }
        bridge.dispose();
      });
    }

    test('ffiZeroCopy stages each new payload once', () async {
      final bridge = FfiPayloadAdapter(BridgeKind.ffiZeroCopy);
      await bridge.warmUp(1024);
      final a = _payload(1024, 1);
      final b = _payload(1024, 2);
      expect(bridge.roundTrip(a), checksum(a));
      expect(bridge.roundTrip(a), checksum(a));
      expect(bridge.roundTrip(b), checksum(b));
      bridge.dispose();
    });
  });

  test('C and Dart preprocessing agree on the same frame', () {
    final frame = makeFakeFrame(width: 97, height: 61, seed: 7);
    final c = NativePreprocessorAdapter();
    final fromC = c.preprocess(frame);
    final fromDart = const DartPreprocessor().preprocess(frame);
    expect(fromC.length, fromDart.length);
    var maxDiff = 0.0;
    for (var i = 0; i < fromC.length; i++) {
      final d = (fromC[i] - fromDart[i]).abs();
      if (d > maxDiff) maxDiff = d;
    }
    expect(maxDiff, lessThan(1e-4));
    c.dispose();
  });

  testWidgets('RealBenchmark runs every suite in order on fakes', (
    tester,
  ) async {
    final meter = FrameMeter(budgetMs: 16.7);
    final host = RealBenchmark(
      payloadBridges: [for (final k in BridgeKind.values) FakePayloadBridge(k)],
      preprocessors: [const DartPreprocessor()],
      classifierAt: (kind, site) => FakeClassifier(kind: kind),
      generators: [FakeTokenGenerator(), _MissingModel()],
      frames: () async => [makeFakeFrame()],
      meter: meter,
      deviceModel: () async => 'Test phone',
      config: const BenchConfig(
        payloadSizes: [0, 1024],
        roundTripWarmup: 1,
        roundTripRuns: 3,
        preprocessRuns: 2,
        classifyRuns: 2,
        jankDuration: Duration(milliseconds: 30),
        generateTokens: 4,
        repeats: 1,
      ),
    );
    final finished = <String, int>{};
    await tester.runAsync(() async {
      await for (final p in host.run()) {
        if (p.done) finished[p.suite] = p.rows.length;
      }
    });
    expect(finished.keys, host.suites);
    expect(finished['Round trip'], 5 * 2);
    expect(finished['Classify'], 4);
    expect(finished['Generate'], 1, reason: 'the missing LLM is skipped');
    final suites = host.results!.suites.map((s) => s.suite).toSet();
    expect(suites, {
      'round_trip',
      'preprocess',
      'classify',
      'jank',
      'generate',
    });
    expect(host.results!.device.model, 'Test phone');
    host.dispose();
    meter.dispose();
  });
}
