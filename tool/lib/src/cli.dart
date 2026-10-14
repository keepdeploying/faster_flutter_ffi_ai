// The command line of bin/report.dart, kept here so tests can call it.

import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'report.dart';

const String usage = '''
Makes a report from a benchmark results file.

Usage: dart run tool/bin/report.dart <results.json> [--out results/]

Writes <out>/<name>.md (tables) and <out>/<name>/*.svg (charts for slides).
''';

ArgParser _parser() => ArgParser()
  ..addOption(
    'out',
    abbr: 'o',
    defaultsTo: 'results',
    help: 'Folder for the report and the chart folder.',
  )
  ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help.');

/// Runs the tool. Returns the exit code: 0 done, 2 bad usage, 1 bad file.
int runReport(List<String> args, {StringSink? out, StringSink? err}) {
  final stdoutSink = out ?? stdout;
  final stderrSink = err ?? stderr;
  final parser = _parser();
  final ArgResults parsed;
  try {
    parsed = parser.parse(args);
  } on FormatException catch (e) {
    stderrSink
      ..writeln(e.message)
      ..writeln()
      ..writeln(usage)
      ..writeln(parser.usage);
    return 2;
  }
  if (parsed['help'] as bool) {
    stdoutSink
      ..writeln(usage)
      ..writeln(parser.usage);
    return 0;
  }
  if (parsed.rest.length != 1) {
    stderrSink
      ..writeln('Give exactly one results file.')
      ..writeln()
      ..writeln(usage)
      ..writeln(parser.usage);
    return 2;
  }

  final input = parsed.rest.single;
  final outDir = parsed['out'] as String;
  try {
    final files = writeReport(input, outDir: outDir);
    stdoutSink.writeln('Wrote ${files.markdown.path}');
    for (final f in files.charts) {
      stdoutSink.writeln('Wrote ${p.normalize(f.path)}');
    }
    for (final name in files.skipped) {
      stdoutSink.writeln('Skipped $name: the file has no data for it.');
    }
    return 0;
  } on FileSystemException catch (e) {
    stderrSink.writeln('${e.message}: ${e.path}');
    return 1;
  } on FormatException catch (e) {
    stderrSink.writeln('Cannot read the results: ${e.message}');
    return 1;
  }
}
