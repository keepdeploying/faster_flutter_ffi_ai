import 'package:faster_flutter/bench/stopwatch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ticksToMicros is monotonic and positive', () {
    final a = nowMicros();
    final b = nowMicros();
    expect(b, greaterThanOrEqualTo(a));
    expect(ticksToMicros(0), 0);
  });

  test('measureSync runs warm-up plus measured calls, returns only runs', () {
    var calls = 0;
    final samples = measureSync(() => calls++, warmup: 3, runs: 7);
    expect(calls, 10);
    expect(samples, hasLength(7));
    expect(samples.every((s) => s >= 0), isTrue);
  });

  test('timeSync sees a 2 ms busy wait', () {
    final us = timeSync(() {
      final sw = Stopwatch()..start();
      while (sw.elapsedMilliseconds < 2) {}
    });
    expect(us, greaterThan(1900));
    expect(us, lessThan(200000));
  });

  test('measureAsync awaits each call', () async {
    var calls = 0;
    final samples = await measureAsync(
      () async {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        calls++;
      },
      warmup: 1,
      runs: 3,
    );
    expect(calls, 4);
    expect(samples, hasLength(3));
    expect(samples.every((s) => s >= 900), isTrue);
  });

  test('timeFutureOr handles a value and a future', () async {
    final sync = await timeFutureOr<int>(() => 7);
    expect(sync.value, 7);
    final later = await timeFutureOr<int>(
      () => Future<int>.delayed(const Duration(milliseconds: 2), () => 9),
    );
    expect(later.value, 9);
    expect(later.micros, greaterThan(1500));
  });
}
