// The Markdown report. Every number in it is copied from the results file;
// the only arithmetic is a ratio of two p50 values, and it says so.

import 'charts/speedup.dart';
import 'format.dart';
import 'model.dart';

/// Writes the report for [r]. [sourceName] is the results file name, [chartDir]
/// the folder name of the charts next to the report (for the image links).
///
/// [charts] names the SVG files that exist (`round_trip.svg`, ...); a chart
/// that is not listed is not linked. Null means all four.
String markdownReport(
  Results r, {
  required String sourceName,
  String? chartDir,
  Set<String>? charts,
}) {
  String? link(String name) =>
      chartDir != null && (charts?.contains(name) ?? true)
      ? '$chartDir/$name'
      : null;

  final out = StringBuffer();
  final d = r.device;
  out
    ..writeln('# Results: ${d.model}, ${r.date}')
    ..writeln()
    ..writeln('| | |')
    ..writeln('| --- | --- |')
    ..writeln('| Device | ${d.model} (${d.platform} ${d.os}, ${d.abi}) |')
    ..writeln('| Flutter | ${r.flutter} |')
    ..writeln('| Build mode | ${r.buildMode} |')
    ..writeln(
      '| Taken | ${r.createdAt.toIso8601String().replaceFirst('.000', '')} |',
    )
    ..writeln('| Source file | `$sourceName` |')
    ..writeln();

  if (r.buildMode == 'debug') {
    out
      ..writeln(
        '> Warning: this file comes from a debug build. Debug numbers '
        'are not honest numbers. Run the benchmark in profile mode.',
      )
      ..writeln();
  }

  if (r.roundTrips.isNotEmpty) _roundTrip(out, r, link);
  if (r.preprocesses.isNotEmpty) _preprocess(out, r);
  if (r.classifies.isNotEmpty) _classify(out, r, link);
  if (r.janks.isNotEmpty) _jank(out, r, link);
  if (r.generates.isNotEmpty) _generate(out, r);

  out
    ..writeln('---')
    ..writeln()
    ..writeln(
      'Written by `tool/bin/report.dart` from `$sourceName`. Do not edit '
      'by hand: run the tool again. Times are microseconds in the file and '
      'shown here with a unit. p50, p95 and p99 are nearest-rank '
      'percentiles of the measured runs.',
    );
  return out.toString();
}

void _roundTrip(StringBuffer out, Results r, String? Function(String) link) {
  final sizes = r.payloadSizes;
  final bridges = (r.roundTrips.map((e) => e.bridge).toSet().toList())
    ..sort(compareBridge);
  out
    ..writeln('## Round trip')
    ..writeln()
    ..writeln(
      'Time for a payload to reach native code and return its checksum. '
      'KB is 1,024 bytes.',
    )
    ..writeln();
  final rtLink = link('round_trip.svg');
  if (rtLink != null) {
    out
      ..writeln('![Round trip p50 per bridge]($rtLink)')
      ..writeln();
  }
  final speed = findSpeedup(r);
  if (speed != null) {
    out
      ..writeln(
        'At ${payloadLabel(speed.payloadBytes)}, MethodChannel p50 is '
        '${formatUs(speed.channelUs)} and FFI leaf p50 is '
        '${formatUs(speed.ffiUs)}: ${formatFactor(speed.factor)} (the first '
        'divided by the second).',
      )
      ..writeln();
    final suLink = link('speedup.svg');
    if (suLink != null) {
      out
        ..writeln('![Speed-up]($suLink)')
        ..writeln();
    }
  }

  out
    ..writeln('p50 by payload size:')
    ..writeln()
    ..writeln('| Payload | ${bridges.map(bridgeLabel).join(' | ')} |')
    ..writeln('| --- | ${bridges.map((_) => '---:').join(' | ')} |');
  for (final s in sizes) {
    final cells = [
      for (final b in bridges)
        r.roundTripOf(b, s) == null
            ? 'n/a'
            : formatUs(r.roundTripOf(b, s)!.stats.p50Us),
    ];
    out.writeln('| ${payloadLabel(s)} | ${cells.join(' | ')} |');
  }
  out
    ..writeln()
    ..writeln('All percentiles:')
    ..writeln()
    ..writeln('| Payload | Bridge | p50 | p95 | p99 | Runs |')
    ..writeln('| --- | --- | ---: | ---: | ---: | ---: |');
  for (final s in sizes) {
    for (final b in bridges) {
      final rt = r.roundTripOf(b, s);
      if (rt == null) continue;
      out.writeln(
        '| ${payloadLabel(s)} | ${bridgeLabel(b)} | '
        '${formatUs(rt.stats.p50Us)} | ${formatUs(rt.stats.p95Us)} | '
        '${formatUs(rt.stats.p99Us)} | ${formatInt(rt.runs)} |',
      );
    }
  }
  out.writeln();
}

void _preprocess(StringBuffer out, Results r) {
  final rows = [...r.preprocesses]..sort((a, b) => a.impl.compareTo(b.impl));
  out
    ..writeln('## Preprocess')
    ..writeln()
    ..writeln(
      'Resize one camera frame to 224 x 224 and scale it to floats in '
      '[-1, 1], in Dart and in C.',
    )
    ..writeln()
    ..writeln('| Implementation | p50 | p95 | p99 | Mean | Runs |')
    ..writeln('| --- | ---: | ---: | ---: | ---: | ---: |');
  for (final p in rows) {
    out.writeln(
      '| ${implLabel(p.impl)} | ${formatUs(p.stats.p50Us)} | '
      '${formatUs(p.stats.p95Us)} | ${formatUs(p.stats.p99Us)} | '
      '${formatUs(p.stats.meanUs)} | ${formatInt(p.runs)} |',
    );
  }
  final dart = rows.where((p) => p.impl == 'dart').firstOrNull;
  final c = rows.where((p) => p.impl == 'c').firstOrNull;
  if (dart != null && c != null && c.stats.p50Us > 0) {
    out
      ..writeln()
      ..writeln(
        'C p50 against Dart p50: '
        '${formatFactor(dart.stats.p50Us / c.stats.p50Us)} (Dart divided by C).',
      );
  }
  out.writeln();
}

void _classify(StringBuffer out, Results r, String? Function(String) link) {
  final rows = [...r.classifies]
    ..sort((a, b) {
      final c = compareBridge(a.bridge, b.bridge);
      return c != 0 ? c : compareSite(a.site, b.site);
    });
  out
    ..writeln('## Classify')
    ..writeln()
    ..writeln(
      'One frame to one label, split into preprocessing, inference and '
      'the rest. The rest is the bridge: total minus preprocess minus '
      'inference.',
    )
    ..writeln();
  final csLink = link('classify_split.svg');
  if (csLink != null) {
    out
      ..writeln('![Where a classify call spends its time]($csLink)')
      ..writeln();
  }
  out
    ..writeln('p50 of each part:')
    ..writeln()
    ..writeln(
      '| Bridge | Site | Total | Preprocess | Inference | Overhead | Runs |',
    )
    ..writeln('| --- | --- | ---: | ---: | ---: | ---: | ---: |');
  for (final c in rows) {
    out.writeln(
      '| ${bridgeLabel(c.bridge)} | ${siteLabel(c.site)} | '
      '${formatUs(c.total.p50Us)} | ${formatUs(c.preprocess.p50Us)} | '
      '${formatUs(c.inference.p50Us)} | ${formatUs(c.overhead.p50Us)} | '
      '${formatInt(c.runs)} |',
    );
  }
  out
    ..writeln()
    ..writeln('Total time, tail:')
    ..writeln()
    ..writeln('| Bridge | Site | p50 | p95 | p99 |')
    ..writeln('| --- | --- | ---: | ---: | ---: |');
  for (final c in rows) {
    out.writeln(
      '| ${bridgeLabel(c.bridge)} | ${siteLabel(c.site)} | '
      '${formatUs(c.total.p50Us)} | ${formatUs(c.total.p95Us)} | '
      '${formatUs(c.total.p99Us)} |',
    );
  }
  out.writeln();
}

void _jank(StringBuffer out, Results r, String? Function(String) link) {
  final rows = [...r.janks]
    ..sort((a, b) {
      final c = compareBridge(a.bridge, b.bridge);
      return c != 0 ? c : compareSite(a.site, b.site);
    });
  out
    ..writeln('## Jank')
    ..writeln()
    ..writeln(
      'Frames that took longer than the budget while the work ran. '
      'A frame is janky when its total time from the engine is over the budget.',
    )
    ..writeln();
  final jLink = link('jank.svg');
  if (jLink != null) {
    out
      ..writeln('![Janky frames per case]($jLink)')
      ..writeln();
  }
  out
    ..writeln(
      '| Bridge | Site | Seconds | Frames | Janky | Janky share | Worst frame | Budget |',
    )
    ..writeln('| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |');
  for (final j in rows) {
    out.writeln(
      '| ${bridgeLabel(j.bridge)} | ${siteLabel(j.site)} | '
      '${j.seconds == j.seconds.roundToDouble() ? j.seconds.round() : formatFixed(j.seconds)} | '
      '${formatInt(j.frames)} | ${formatInt(j.jankyFrames)} | '
      '${formatFixed(j.jankyPercent)}% | ${formatFixed(j.worstFrameMs)} ms | '
      '${formatFixed(j.budgetMs)} ms |',
    );
  }
  out.writeln();
}

void _generate(StringBuffer out, Results r) {
  out
    ..writeln('## Generate')
    ..writeln()
    ..writeln(
      'Streaming tokens from native code to the screen. First token is '
      'the time until the first token reaches Dart.',
    )
    ..writeln()
    ..writeln(
      '| Generator | Tokens | First token | Tokens per second | Janky frames |',
    )
    ..writeln('| --- | ---: | ---: | ---: | ---: |');
  for (final g in r.generates) {
    out.writeln(
      '| ${generatorLabel(g.generator)} | ${formatInt(g.tokens)} | '
      '${formatMs(g.firstTokenMs)} | ${formatFixed(g.tokensPerSec)} | '
      '${formatInt(g.jankyFrames)} |',
    );
  }
  out.writeln();
}
