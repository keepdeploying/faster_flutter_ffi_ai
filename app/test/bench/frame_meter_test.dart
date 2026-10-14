import 'package:faster_flutter/bench/frame_meter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('budget falls back to 60 Hz or follows the display', () {
    final ms = FrameMeter.detectBudgetMs();
    expect(ms, greaterThan(0));
    expect(ms, lessThanOrEqualTo(1000 / 24));
  });

  test('counts frames over the budget and tracks the worst', () {
    final meter = FrameMeter(budgetMs: 16.7);
    meter.recordFrameMs(5);
    meter.recordFrameMs(16.7); // equal to the budget is not janky
    meter.recordFrameMs(16.8);
    meter.recordFrameMs(40);
    final s = meter.summary;
    expect(s.frames, 4);
    expect(s.jankyFrames, 2);
    expect(s.worstFrameMs, 40);
    expect(s.budgetMs, 16.7);
    expect(meter.jankCount.value, 2);
    meter.dispose();
  });

  test('the recent window keeps the last N frames, oldest first', () {
    final meter = FrameMeter(windowSize: 3, budgetMs: 16.7);
    for (var i = 1; i <= 5; i++) {
      meter.recordFrameMs(i.toDouble());
    }
    expect(meter.recent.value, [3.0, 4.0, 5.0]);
    expect(meter.summary.frames, 5);
    meter.dispose();
  });

  test('a published list is not changed by later frames', () {
    final meter = FrameMeter(windowSize: 3, budgetMs: 16.7);
    meter.recordFrameMs(1);
    final first = meter.recent.value;
    meter.recordFrameMs(2);
    expect(first, [1.0]);
    expect(() => first.add(9), throwsUnsupportedError);
    meter.dispose();
  });

  test('reset clears counts and listeners hear about it', () {
    final meter = FrameMeter(budgetMs: 10);
    meter.recordFrameMs(50);
    var notified = 0;
    meter.jankCount.addListener(() => notified++);
    meter.reset();
    expect(meter.summary.frames, 0);
    expect(meter.jankCount.value, 0);
    expect(meter.recent.value, isEmpty);
    expect(notified, 1);
    meter.dispose();
  });

  test('start and stop are safe to repeat', () {
    final meter = FrameMeter();
    meter.start();
    meter.start();
    expect(meter.isRunning, isTrue);
    meter.stop();
    meter.stop();
    expect(meter.isRunning, isFalse);
    meter.dispose();
    meter.dispose();
  });
}
