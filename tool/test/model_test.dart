import 'package:faster_flutter_tool/faster_flutter_tool.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('Results.parse', () {
    test('reads every suite type in the sample file', () {
      final r = loadFixture('sample_results.json');
      expect(r.device.model, 'Fixture phone');
      expect(r.device.abi, 'android_arm64');
      expect(r.flutter, '3.47.6');
      expect(r.buildMode, 'profile');
      expect(r.date, '2026-10-14');
      expect(r.roundTrips, hasLength(25));
      expect(r.preprocesses, hasLength(2));
      expect(r.classifies, hasLength(6));
      expect(r.janks, hasLength(6));
      expect(r.generates, hasLength(2));
      expect(r.suites.map((s) => s.suite).toSet(), {
        'round_trip',
        'preprocess',
        'classify',
        'jank',
        'generate',
      });
    });

    test('finds a round trip by bridge and payload', () {
      final r = loadFixture('sample_results.json');
      expect(r.payloadSizes, [0, 1024, 65536, 602112, 8294400]);
      expect(r.roundTripOf('ffiLeaf', 602112)!.stats.p50Us, 36);
      expect(r.roundTripOf('ffiLeaf', 7), isNull);
    });

    test('classify reads the overhead object', () {
      final c = loadFixture('sample_results.json').classifies.first;
      expect(c.overhead.p50Us, greaterThan(0));
      expect(
        c.total.p50Us,
        c.preprocess.p50Us + c.inference.p50Us + c.overhead.p50Us,
      );
    });

    test('classify accepts the first-draft schema (stats under "bridge")', () {
      final c = loadFixture('legacy_classify.json').classifies.single;
      expect(c.bridge, '');
      expect(c.overhead.p50Us, 2000);
    });

    test('jank computes the share of janky frames', () {
      final j = loadFixture('sample_results.json').janks.first;
      expect(j.jankyPercent, closeTo(100 * j.jankyFrames / j.frames, 1e-9));
    });

    test('missing stats keys read as zero', () {
      final r = Results.parse('''
{"schema":1,"createdAt":"2026-10-14T10:00:00Z",
 "device":{"platform":"android","model":"X","os":"16","abi":"android_arm64"},
 "flutter":"3.47.6","buildMode":"profile",
 "suites":[{"suite":"preprocess","impl":"c","runs":5,"stats":{}}]}''');
      expect(r.preprocesses.single.stats.p50Us, 0);
    });

    test('rejects what is not a results file', () {
      expect(() => Results.parse('nope'), throwsFormatException);
      expect(() => Results.parse('[]'), throwsFormatException);
      expect(() => Results.parse('{"schema":2}'), throwsFormatException);
      expect(() => Results.parse('{"schema":1}'), throwsFormatException);
      expect(
        () => Results.parse(
          '''
{"schema":1,"createdAt":"2026-10-14T10:00:00Z","device":{},"suites":[{"suite":"x"}]}''',
        ),
        throwsFormatException,
      );
    });
  });

  test('bridges and sites sort in talk order, unknown names last', () {
    final bridges = ['ffiLeaf', 'zzz', 'methodChannel', 'ffiCopy']
      ..sort(compareBridge);
    expect(bridges, ['methodChannel', 'ffiCopy', 'ffiLeaf', 'zzz']);
    final sites = ['nativeThread', 'uiThread', 'isolate']..sort(compareSite);
    expect(sites, ['uiThread', 'isolate', 'nativeThread']);
  });
}
