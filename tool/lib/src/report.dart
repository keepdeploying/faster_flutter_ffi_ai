// Reads a results file and writes the report next to it.

import 'dart:io';

import 'package:path/path.dart' as p;

import 'charts/classify_split.dart';
import 'charts/jank.dart';
import 'charts/round_trip.dart';
import 'charts/speedup.dart';
import 'markdown.dart';
import 'model.dart';

/// What [writeReport] wrote.
class ReportFiles {
  ReportFiles({
    required this.markdown,
    required this.charts,
    required this.skipped,
  });

  final File markdown;
  final List<File> charts;

  /// Charts that were left out because the file has no data for them.
  final List<String> skipped;
}

/// The report name for a results file: its name without `.json`.
String stemOf(String inputPath) {
  final base = p.basename(inputPath);
  return base.toLowerCase().endsWith('.json')
      ? base.substring(0, base.length - 5)
      : base;
}

/// Writes `<out>/<stem>.md` and `<out>/<stem>/*.svg` for the results file at
/// [inputPath].
ReportFiles writeReport(String inputPath, {required String outDir}) {
  final input = File(inputPath);
  if (!input.existsSync()) {
    throw FileSystemException('Results file not found', inputPath);
  }
  final Results results;
  try {
    results = Results.parse(input.readAsStringSync());
  } on FormatException catch (e) {
    throw FormatException('$inputPath: ${e.message}');
  }

  final stem = stemOf(inputPath);
  final chartDir = Directory(p.join(outDir, stem))..createSync(recursive: true);

  final charts = <String, String?>{
    'round_trip.svg': roundTripChart(results),
    'classify_split.svg': classifySplitChart(results),
    'jank.svg': jankChart(results),
    'speedup.svg': speedupChart(results),
  };
  final written = <File>[];
  final skipped = <String>[];
  final present = <String>{};
  charts.forEach((name, svg) {
    if (svg == null) {
      skipped.add(name);
      return;
    }
    final f = File(p.join(chartDir.path, name))..writeAsStringSync(svg);
    written.add(f);
    present.add(name);
  });

  final md = File(p.join(outDir, '$stem.md'));
  md.writeAsStringSync(
    markdownReport(
      results,
      sourceName: p.basename(inputPath),
      chartDir: stem,
      charts: present,
    ),
  );
  return ReportFiles(markdown: md, charts: written, skipped: skipped);
}
