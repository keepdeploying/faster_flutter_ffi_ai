// classify_split.svg: where the time of one classify call goes, as stacked
// horizontal bars: preprocess, inference, and the bridge overhead (coloured
// by bridge family: red for channels, green for FFI).

import 'dart:math' as math;

import '../format.dart';
import '../model.dart';
import '../svg.dart';
import '../theme.dart';

const double _plotL = 440;
const double _plotR = 1130;
const double _plotT = 235;
const double _plotB = 740;

/// Returns the chart, or null when the file has no classify results.
String? classifySplitChart(Results r) {
  final rows = [...r.classifies]
    ..sort((a, b) {
      final c = compareSite(a.site, b.site);
      return c != 0 ? c : compareBridge(a.bridge, b.bridge);
    });
  if (rows.isEmpty) return null;

  double sum(Classify c) =>
      c.preprocess.p50Us + c.inference.p50Us + c.overhead.p50Us;
  final maxUs = rows
      .map((c) => math.max(sum(c), c.total.p50Us))
      .reduce(math.max);
  if (maxUs <= 0) return null;

  // Axis in ms when the slowest bar is a millisecond or more, else in µs.
  final inMs = maxUs >= 1000;
  final unit = inMs ? 1000.0 : 1.0;
  final ticks = niceTicks(maxUs / unit, count: 5);
  final axisMax = ticks.last * unit;
  double xOf(double us) => _plotL + us / axisMax * (_plotR - _plotL);

  final sites = rows.map((c) => c.site).toSet();
  final body = StringBuffer();

  // Key: direct names for the three parts, no box.
  var kx = 80.0;
  const ky = 196.0;
  void key(String label, List<String> colors) {
    final w = 26.0 / colors.length;
    for (var i = 0; i < colors.length; i++) {
      body.write(svgRect(kx + i * w, ky - 22, w, 26, fill: colors[i]));
    }
    body.write(svgText(kx + 38, ky, label, size: 26));
    kx += 38 + label.length * 14.5 + 44;
  }

  key('preprocess', [inkLight]);
  key('inference', [inkMid]);
  key('bridge overhead', [channelRed, ffiGreen]);

  // Axis grid and labels.
  for (final t in ticks) {
    final x = xOf(t * unit);
    body
      ..write(svgLine(x, _plotT - 10, x, _plotB, stroke: grid, width: 2))
      ..write(
        svgText(
          x,
          _plotB + 40,
          formatTick(t, inMs),
          size: 24,
          fill: quiet,
          anchor: 'middle',
          code: true,
        ),
      );
  }

  final n = rows.length;
  final rowH = math.min(96.0, (_plotB - _plotT) / n);
  final barH = rowH * 0.62;
  final twoLine = rowH >= 64;
  for (var i = 0; i < n; i++) {
    final c = rows[i];
    final cy = _plotT + rowH * (i + 0.5);
    final top = cy - barH / 2;

    // Row label.
    final name = bridgeLabel(c.bridge);
    final site = siteLabel(c.site);
    if (twoLine && sites.length > 1) {
      body
        ..write(
          svgText(
            _plotL - 24,
            cy - 4,
            name,
            size: 28,
            anchor: 'end',
            bold: true,
            fill: labelColor(c.bridge),
          ),
        )
        ..write(
          svgText(
            _plotL - 24,
            cy + 26,
            site,
            size: 24,
            anchor: 'end',
            fill: quiet,
          ),
        );
    } else {
      final text = sites.length > 1 ? '$name · $site' : name;
      body.write(
        svgText(
          _plotL - 24,
          cy + 9,
          text,
          size: 28,
          anchor: 'end',
          bold: true,
          fill: labelColor(c.bridge),
        ),
      );
    }

    // Segments, left to right.
    final parts = <({double us, String color})>[
      (us: c.preprocess.p50Us, color: inkLight),
      (us: c.inference.p50Us, color: inkMid),
      (us: c.overhead.p50Us, color: barColor(c.bridge)),
    ];
    var x = _plotL;
    for (final p in parts) {
      final w = p.us / axisMax * (_plotR - _plotL);
      if (w <= 0) continue;
      body.write(
        svgRect(
          x,
          top,
          w,
          barH,
          fill: p.color,
          extra: 'stroke="$paper" stroke-width="2"',
        ),
      );
      if (w >= 112) {
        body.write(
          svgText(
            x + w / 2,
            cy + 8,
            formatUs(p.us),
            size: 24,
            anchor: 'middle',
            code: true,
            bold: true,
            fill: onColor(p.color),
          ),
        );
      }
      x += w;
    }
    // Overhead too thin to hold text: say it at the end of the bar.
    final oh = c.overhead.p50Us;
    final ohW = oh / axisMax * (_plotR - _plotL);
    final ohNote = ohW < 112 ? ' · bridge ${formatUs(oh)}' : '';
    body.writeln(
      '<text x="${num2(x + 18)}" y="${num2(cy + 9)}" font-size="26" '
      'fill="$ink"><tspan font-family="$codeFont" font-weight="700">'
      '${xmlEscape(formatUs(c.total.p50Us))}</tspan>'
      '<tspan font-family="$textFont" fill="$quiet" font-size="22" dx="10">'
      '${xmlEscape(' total$ohNote')}</tspan></text>',
    );
  }

  body.write(
    svgText(
      80,
      828,
      'Each segment is the p50 of that part, so segments can differ a little '
      'from the p50 of the whole call.',
      size: 20,
      fill: quiet,
    ),
  );

  return chartFrame(
    title: 'Where a classify call spends its time',
    subtitle:
        'One frame in, one label out. The only difference between '
        'the bars is the bridge.',
    source: sourceLine(r),
    body: body.toString(),
    description:
        'Stacked horizontal bars of preprocess, inference and '
        'bridge overhead time per bridge and execution site.',
  );
}

/// A tick on the time axis: `0`, `5 ms`, `250 µs`.
String formatTick(double v, bool inMs) {
  final s = v == v.roundToDouble() ? v.round().toString() : v.toString();
  if (v == 0) return '0';
  return inMs ? '$s ms' : '$s µs';
}
