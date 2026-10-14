// speedup.svg: one big number. Channel p50 divided by FFI leaf p50 for the
// 224x224 float32 tensor, the payload of one classify call.

import '../format.dart';
import '../model.dart';
import '../svg.dart';
import '../theme.dart';

/// The payload the headline number is taken at: the model input, 602,112
/// bytes. If the file has no round trip of that size, the closest one is used.
const int headlinePayloadBytes = 602112;

/// The numbers behind the headline.
class Speedup {
  const Speedup({
    required this.payloadBytes,
    required this.channelUs,
    required this.ffiUs,
  });

  final int payloadBytes;

  /// `methodChannel` p50.
  final double channelUs;

  /// `ffiLeaf` p50.
  final double ffiUs;

  double get factor => channelUs / ffiUs;
}

/// Finds the headline numbers, or null when the file cannot give them (no
/// channel or no leaf round trip, or a leaf p50 of zero).
Speedup? findSpeedup(Results r) {
  final sizes = r.payloadSizes.where((s) {
    return r.roundTripOf('methodChannel', s) != null &&
        r.roundTripOf('ffiLeaf', s) != null;
  }).toList();
  if (sizes.isEmpty) return null;
  sizes.sort(
    (a, b) => (a - headlinePayloadBytes).abs().compareTo(
      (b - headlinePayloadBytes).abs(),
    ),
  );
  final size = sizes.first;
  final channel = r.roundTripOf('methodChannel', size)!.stats.p50Us;
  final ffi = r.roundTripOf('ffiLeaf', size)!.stats.p50Us;
  if (ffi <= 0 || channel <= 0) return null;
  return Speedup(payloadBytes: size, channelUs: channel, ffiUs: ffi);
}

/// Returns the chart, or null when [findSpeedup] has nothing.
String? speedupChart(Results r) {
  final s = findSpeedup(r);
  if (s == null) return null;

  final body = StringBuffer()
    ..write(
      svgText(
        800,
        520,
        formatFactor(s.factor),
        size: 300,
        fill: ffiGreen,
        anchor: 'middle',
        bold: true,
        code: true,
      ),
    )
    ..write(
      svgText(
        800,
        600,
        'MethodChannel p50 ÷ FFI leaf p50',
        size: 40,
        anchor: 'middle',
        bold: true,
      ),
    )
    ..write(
      svgText(
        800,
        650,
        'for ${payloadLabel(s.payloadBytes)} '
        '(${formatInt(s.payloadBytes)} bytes), same bytes, same phone',
        size: 28,
        fill: quiet,
        anchor: 'middle',
      ),
    );

  // The two numbers behind it, side by side, each in its own colour.
  final cx = [470.0, 1130.0];
  final items = [
    ('MethodChannel', formatUs(s.channelUs), channelRed),
    ('FFI leaf', formatUs(s.ffiUs), ffiGreen),
  ];
  for (var i = 0; i < 2; i++) {
    body
      ..write(svgRect(cx[i] - 170, 716, 340, 8, fill: items[i].$3))
      ..write(
        svgText(
          cx[i],
          772,
          items[i].$2,
          size: 44,
          anchor: 'middle',
          bold: true,
          code: true,
        ),
      )
      ..write(
        svgText(
          cx[i],
          812,
          items[i].$1,
          size: 26,
          fill: quiet,
          anchor: 'middle',
        ),
      );
  }

  return chartFrame(
    title: 'One call, two bridges',
    subtitle: s.factor >= 1
        ? 'How many times faster the FFI leaf call is than the method channel.'
        : 'In this run the FFI leaf call was not faster than the method channel.',
    source: sourceLine(r),
    body: body.toString(),
    description:
        'The method channel round trip p50 divided by the FFI leaf '
        'round trip p50: ${formatFactor(s.factor)}.',
  );
}

/// Convenience for tests: the factor rounded the way the chart prints it.
String headline(Speedup s) => formatFactor(s.factor);
