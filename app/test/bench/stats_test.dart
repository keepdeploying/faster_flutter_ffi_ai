import 'package:faster_flutter/bench/stats.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LatencyStats nearest rank', () {
    test('1..100 gives the sample at the rank itself', () {
      // Shuffled on purpose: the order of the input must not matter.
      final samples = [for (var i = 100; i >= 1; i--) i.toDouble()]..shuffle();
      final s = LatencyStats.fromSamples(samples);
      expect(s.p50Us, 50);
      expect(s.p95Us, 95);
      expect(s.p99Us, 99);
      expect(s.meanUs, closeTo(50.5, 1e-9));
      expect(s.minUs, 1);
      expect(s.maxUs, 100);
      expect(s.count, 100);
    });

    test('ten samples: rank rounds up, p95 and p99 are the maximum', () {
      final s = LatencyStats.fromSamples([
        for (var i = 1; i <= 10; i++) i.toDouble(),
      ]);
      expect(s.p50Us, 5); // ceil(5.0) = rank 5
      expect(s.p95Us, 10); // ceil(9.5) = rank 10
      expect(s.p99Us, 10);
    });

    test('result is always a measured value, never interpolated', () {
      final s = LatencyStats.fromSamples([1, 2, 100]);
      expect(s.p50Us, 2); // ceil(1.5) = rank 2
      expect([1.0, 2.0, 100.0], contains(s.p95Us));
    });

    test('one sample fills every field', () {
      final s = LatencyStats.fromSamples([3.5]);
      expect(
        [s.p50Us, s.p95Us, s.p99Us, s.meanUs, s.minUs, s.maxUs],
        [3.5, 3.5, 3.5, 3.5, 3.5, 3.5],
      );
    });

    test('whole-number ranks are exact (no float drift)', () {
      // 0.07 * 100 style drift would pick rank 8 here.
      final list = [for (var i = 1; i <= 100; i++) i.toDouble()];
      expect(LatencyStats.nearestRank(list, 7), 7);
      expect(LatencyStats.nearestRank(list, 29), 29);
    });

    test('empty input is an error', () {
      expect(() => LatencyStats.fromSamples([]), throwsArgumentError);
    });
  });

  group('LatencyStats json', () {
    test('toJson has exactly the six schema keys and round trips', () {
      final s = LatencyStats.fromSamples([0.3, 0.4, 0.5, 0.6, 12.0]);
      final json = s.toJson();
      expect(json.keys, [
        'p50Us',
        'p95Us',
        'p99Us',
        'meanUs',
        'minUs',
        'maxUs',
      ]);
      expect(LatencyStats.fromJson(json), s);
    });

    test('an empty stats object (abbreviated in the docs) parses', () {
      final s = LatencyStats.fromJson(const {});
      expect(s.p50Us, 0);
    });
  });

  group('medianBy', () {
    test('picks the middle element by key', () {
      expect(medianBy([5.0, 1.0, 3.0], (x) => x), 3.0);
    });
    test('even count picks the lower middle', () {
      expect(medianBy([4.0, 1.0, 3.0, 2.0], (x) => x), 2.0);
    });
  });
}
