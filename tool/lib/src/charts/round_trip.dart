// round_trip.svg: p50 per bridge across payload sizes, log-scale y, one line
// per bridge, labelled at the line ends. No legend box.

import 'dart:math' as math;

import '../format.dart';
import '../model.dart';
import '../svg.dart';
import '../theme.dart';

const double _plotL = 190;
const double _plotR = 1070;
const double _plotT = 215;
const double _plotB = 735;

/// Lowest value drawn on the log axis (microseconds). A p50 of 0 is a timer
/// reading below its resolution, so it sits on this floor.
const double _floorUs = 0.1;

/// `0.1 µs`, `1 µs`, `10 µs`, `1 ms`, `100 ms`, `1 s` for a decade value.
String decadeLabel(double us) {
  if (us < 1) return '${us.toString()} µs';
  if (us < 1000) return '${us.round()} µs';
  if (us < 1e6) return '${(us / 1000).round()} ms';
  return '${(us / 1e6).round()} s';
}

/// Returns the chart, or null when the file has no round trips.
String? roundTripChart(Results r) {
  final sizes = r.payloadSizes;
  final bridges = (r.roundTrips.map((e) => e.bridge).toSet().toList())
    ..sort(compareBridge);
  if (sizes.isEmpty || bridges.isEmpty) return null;

  double value(String bridge, int size) {
    final rt = r.roundTripOf(bridge, size);
    return rt == null ? double.nan : math.max(rt.stats.p50Us, _floorUs);
  }

  final all = <double>[
    for (final b in bridges)
      for (final s in sizes)
        if (!value(b, s).isNaN) value(b, s),
  ];
  if (all.isEmpty) return null;
  var lo = all.reduce(math.min);
  var hi = all.reduce(math.max);

  // The frame budget joins the chart when the slowest line is within about
  // a decade and a half of it, so "does it fit in a frame" can be read.
  final budgetMs = r.janks.isEmpty ? 16.7 : r.janks.first.budgetMs;
  final budgetUs = budgetMs * 1000;
  final showBudget = hi >= budgetUs / 30;
  if (showBudget) hi = math.max(hi, budgetUs);

  var yLo = math.pow(10, (math.log(lo) / math.ln10).floor()).toDouble();
  var yHi = math.pow(10, (math.log(hi) / math.ln10).ceil()).toDouble();
  if (yHi <= yLo) yHi = yLo * 10;
  final logLo = math.log(yLo) / math.ln10;
  final logHi = math.log(yHi) / math.ln10;

  double yOf(double v) =>
      _plotB -
      (math.log(v) / math.ln10 - logLo) / (logHi - logLo) * (_plotB - _plotT);
  final n = sizes.length;
  double xOf(int i) => n == 1
      ? (_plotL + _plotR) / 2
      : _plotL + 50 + i * (_plotR - _plotL - 100) / (n - 1);

  final body = StringBuffer();

  // Grid and y tick labels, one per decade.
  for (final t in decadeTicks(yLo, yHi)) {
    final y = yOf(t);
    body
      ..write(svgLine(_plotL, y, _plotR, y, stroke: grid, width: 2))
      ..write(
        svgText(
          _plotL - 18,
          y + 8,
          decadeLabel(t),
          size: 24,
          fill: quiet,
          anchor: 'end',
          code: true,
        ),
      );
  }
  body.write(
    svgText(
      _plotL,
      _plotT - 24,
      'p50 round trip, log scale',
      size: 24,
      fill: quiet,
    ),
  );

  // X tick labels.
  for (var i = 0; i < n; i++) {
    body.write(
      svgText(
        xOf(i),
        _plotB + 50,
        payloadLabel(sizes[i]),
        size: 26,
        anchor: 'middle',
        code: true,
      ),
    );
  }
  body.write(
    svgText(
      _plotR,
      _plotB + 98,
      'payload size →',
      size: 24,
      fill: quiet,
      anchor: 'end',
    ),
  );

  // Frame budget.
  if (showBudget) {
    final y = yOf(budgetUs);
    body
      ..write(
        svgLine(
          _plotL,
          y,
          _plotR,
          y,
          stroke: budgetYellow,
          width: 4,
          dash: '14 10',
        ),
      )
      ..write(
        svgText(
          _plotL + 8,
          y - 12,
          'one frame, ${formatFixed(budgetMs)} ms',
          size: 24,
          fill: ink,
          bold: true,
        ),
      );
  }

  // Lines, in bridge order so the FFI lines draw on top of the channel ones.
  final ends = <String, ({double x, double y, double v})>{};
  for (final b in bridges) {
    final st = styleOf(b);
    final pts = <({double x, double y})>[];
    final segments = <List<({double x, double y})>>[[]];
    for (var i = 0; i < n; i++) {
      final v = value(b, sizes[i]);
      if (v.isNaN) {
        if (segments.last.isNotEmpty) segments.add([]);
        continue;
      }
      final p = (x: xOf(i), y: yOf(v));
      pts.add(p);
      segments.last.add(p);
      ends[b] = (x: p.x, y: p.y, v: v);
    }
    for (final seg in segments) {
      if (seg.length < 2) continue;
      final d = [
        for (var k = 0; k < seg.length; k++)
          '${k == 0 ? 'M' : 'L'}${num2(seg[k].x)} ${num2(seg[k].y)}',
      ].join(' ');
      body.writeln(
        '<path d="$d" fill="none" stroke="${st.color}" '
        'stroke-width="${num2(st.width)}" stroke-linecap="round" '
        'stroke-linejoin="round"'
        '${st.dash == null ? '' : ' stroke-dasharray="${st.dash}"'}/>',
      );
    }
    for (final p in pts) {
      body.writeln(
        '<circle cx="${num2(p.x)}" cy="${num2(p.y)}" r="8" '
        'fill="${st.color}" stroke="$paper" stroke-width="3"/>',
      );
    }
  }

  // Direct labels at the line ends, pushed apart so they never overlap.
  final labelled = bridges.where(ends.containsKey).toList();
  final ys = spreadLabels(
    [for (final b in labelled) ends[b]!.y],
    minGap: 36,
    top: _plotT,
    bottom: _plotB,
  );
  for (var k = 0; k < labelled.length; k++) {
    final b = labelled[k];
    final e = ends[b]!;
    final y = ys[k];
    final st = styleOf(b);
    // A short leader from the last point to the label when it was moved.
    if ((y - e.y).abs() > 2) {
      body.write(
        svgLine(e.x + 12, e.y, e.x + 30, y, stroke: st.color, width: 2),
      );
    }
    body.writeln(
      '<text x="${num2(e.x + 38)}" y="${num2(y + 9)}" font-size="28" '
      'fill="$ink"><tspan font-family="$textFont">${xmlEscape(bridgeLabel(b))}'
      '</tspan><tspan font-family="$codeFont" font-weight="700" dx="12" '
      'fill="${labelColor(b)}">${xmlEscape(formatUs(e.v))}</tspan></text>',
    );
  }

  return chartFrame(
    title: 'Round trip: channels vs FFI',
    subtitle:
        'Time for a payload to reach native code and come back. '
        'Lower is faster.',
    source: sourceLine(r),
    body: body.toString(),
    description:
        'Line chart of the p50 round trip time of each bridge '
        'across payload sizes, on a log scale.',
  );
}
