// jank.svg: share of frames that missed the budget while the work ran, one
// bar per case (bridge and execution site). Longer is worse.

import 'dart:math' as math;

import '../format.dart';
import '../model.dart';
import '../svg.dart';
import '../theme.dart';

const double _plotL = 440;
const double _plotR = 1130;
const double _plotT = 235;
const double _plotB = 740;

/// Returns the chart, or null when the file has no jank results.
String? jankChart(Results r) {
  final rows = [...r.janks]
    ..sort((a, b) {
      final c = compareSite(a.site, b.site);
      return c != 0 ? c : compareBridge(a.bridge, b.bridge);
    });
  if (rows.isEmpty) return null;

  final maxPct = rows.map((j) => j.jankyPercent).reduce(math.max);
  // At least a 10 percent axis, so a clean run does not stretch a speck.
  final ticks = niceTicks(math.max(maxPct, 10), count: 5);
  final axisMax = ticks.last;
  double xOf(double pct) => _plotL + pct / axisMax * (_plotR - _plotL);

  final budgetMs = rows.first.budgetMs;
  final sites = rows.map((j) => j.site).toSet();
  final body = StringBuffer()
    ..write(
      svgLine(80, 186, 130, 186, stroke: budgetYellow, width: 6, dash: '14 8'),
    )
    ..write(
      svgText(
        146,
        195,
        'frame budget ${formatFixed(budgetMs)} ms: a frame over it is janky',
        size: 26,
      ),
    );

  for (final t in ticks) {
    final x = xOf(t);
    body
      ..write(svgLine(x, _plotT - 10, x, _plotB, stroke: grid, width: 2))
      ..write(
        svgText(
          x,
          _plotB + 40,
          t == 0 ? '0' : '${_pct(t)}%',
          size: 24,
          fill: quiet,
          anchor: 'middle',
          code: true,
        ),
      );
  }
  body.write(
    svgText(
      _plotR,
      _plotB + 82,
      'share of frames over budget →',
      size: 24,
      fill: quiet,
      anchor: 'end',
    ),
  );

  final n = rows.length;
  final rowH = math.min(96.0, (_plotB - _plotT) / n);
  final barH = rowH * 0.62;
  final twoLine = rowH >= 64;
  for (var i = 0; i < n; i++) {
    final j = rows[i];
    final cy = _plotT + rowH * (i + 0.5);
    final name = bridgeLabel(j.bridge);
    final site = siteLabel(j.site);
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
            fill: labelColor(j.bridge),
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
          fill: labelColor(j.bridge),
        ),
      );
    }
    final w = j.jankyPercent / axisMax * (_plotR - _plotL);
    // A bar of zero is drawn as a hairline so the row still shows a result.
    body.write(
      svgRect(
        _plotL,
        cy - barH / 2,
        math.max(w, 4),
        barH,
        fill: barColor(j.bridge),
      ),
    );
    body.writeln(
      '<text x="${num2(_plotL + math.max(w, 4) + 18)}" y="${num2(cy + 9)}" '
      'font-size="26" fill="$ink"><tspan font-family="$codeFont" '
      'font-weight="700">${j.jankyFrames} of ${formatInt(j.frames)}</tspan>'
      '<tspan font-family="$textFont" fill="$quiet" font-size="22" dx="10">'
      'frames · worst ${xmlEscape(formatFixed(j.worstFrameMs))} ms</tspan></text>',
    );
  }

  return chartFrame(
    title: 'Dropped frames while the work runs',
    subtitle:
        'The same call, the same phone, a ${_secs(rows.first.seconds)} '
        'run per bar. Shorter is smoother.',
    source: sourceLine(r),
    body: body.toString(),
    description:
        'Bar chart of the share of janky frames per bridge and '
        'execution site.',
  );
}

String _pct(double t) =>
    t == t.roundToDouble() ? t.round().toString() : t.toString();

String _secs(double s) =>
    s == s.roundToDouble() ? '${s.round()} s' : '${s.toStringAsFixed(1)} s';
