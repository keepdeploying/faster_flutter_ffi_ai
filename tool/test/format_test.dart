import 'package:faster_flutter_tool/faster_flutter_tool.dart';
import 'package:test/test.dart';

void main() {
  test('formatUs picks a unit and three significant figures', () {
    expect(formatUs(0.42), '0.42 µs');
    expect(formatUs(38.5), '38.5 µs');
    expect(formatUs(540), '540 µs');
    expect(formatUs(1100), '1.10 ms');
    expect(formatUs(38000), '38.0 ms');
    expect(formatUs(2100000), '2.10 s');
    expect(formatUs(0), '0 µs');
    expect(formatUs(double.nan), 'n/a');
  });

  test('formatInt groups thousands', () {
    expect(formatInt(0), '0');
    expect(formatInt(999), '999');
    expect(formatInt(1800), '1,800');
    expect(formatInt(8294400), '8,294,400');
  });

  test('payloadLabel uses 1024 for KB and MB', () {
    expect(payloadLabel(0), '0 B');
    expect(payloadLabel(1024), '1 KB');
    expect(payloadLabel(65536), '64 KB');
    expect(payloadLabel(602112), '588 KB');
    expect(payloadLabel(8294400), '7.9 MB');
  });

  test('formatFactor', () {
    expect(formatFactor(142.3), '142×');
    expect(formatFactor(14.23), '14.2×');
    expect(formatFactor(3.4), '3.4×');
    expect(formatFactor(0.8), '0.80×');
  });

  test('niceTicks start at zero and cover the maximum', () {
    for (final max in [0.7, 3.0, 38.7, 412.0, 9999.0]) {
      final t = niceTicks(max);
      expect(t.first, 0);
      expect(t.last, greaterThanOrEqualTo(max));
      expect(t.length, inInclusiveRange(3, 9));
    }
    expect(niceTicks(0), [0, 1]);
  });

  test('decadeTicks and their labels', () {
    expect(decadeTicks(0.3, 540), [0.1, 1, 10, 100, 1000]);
    expect(decadeLabel(0.1), '0.1 µs');
    expect(decadeLabel(10), '10 µs');
    expect(decadeLabel(1000), '1 ms');
    expect(decadeLabel(100000), '100 ms');
    expect(decadeLabel(1e6), '1 s');
  });

  test('spreadLabels keeps order and a minimum gap inside the bounds', () {
    final out = spreadLabels(
      [300, 301, 302, 305, 500],
      minGap: 36,
      top: 200,
      bottom: 740,
    );
    for (var i = 1; i < out.length; i++) {
      expect(out[i] - out[i - 1], greaterThanOrEqualTo(36 - 1e-9));
    }
    expect(out.first, greaterThanOrEqualTo(200));
    expect(out.last, lessThanOrEqualTo(740));
  });

  test('spreadLabels works on unsorted input and at the bottom edge', () {
    final out = spreadLabels(
      [740, 735, 100],
      minGap: 40,
      top: 100,
      bottom: 740,
    );
    expect(out[2], 100);
    expect(out[0] - out[1], greaterThanOrEqualTo(40 - 1e-9));
    expect(out[0], lessThanOrEqualTo(740));
  });

  test('xmlEscape', () {
    expect(xmlEscape('a<b>&"c'), 'a&lt;b&gt;&amp;&quot;c');
  });

  test('num2 trims zeros', () {
    expect(num2(1.0), '1');
    expect(num2(1.5), '1.5');
    expect(num2(1.234), '1.23');
    expect(num2(-0.001), '0');
  });
}
