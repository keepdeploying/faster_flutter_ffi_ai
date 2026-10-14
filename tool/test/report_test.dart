import 'dart:io';

import 'package:faster_flutter_tool/faster_flutter_tool.dart';
import 'package:faster_flutter_tool/src/cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('ffb_report_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('stemOf drops the .json', () {
    expect(stemOf('results/raw/2026-10-14_pixel-8.json'), '2026-10-14_pixel-8');
    expect(stemOf('a/b/c'), 'c');
  });

  test('writeReport writes the Markdown and the four charts', () {
    final files = writeReport(
      fixturePath('sample_results.json'),
      outDir: tmp.path,
    );
    expect(files.markdown.path, p.join(tmp.path, 'sample_results.md'));
    expect(files.skipped, isEmpty);
    final names = files.charts.map((f) => p.basename(f.path)).toList()..sort();
    expect(names, [
      'classify_split.svg',
      'jank.svg',
      'round_trip.svg',
      'speedup.svg',
    ]);
    for (final f in files.charts) {
      expect(f.existsSync(), isTrue);
      expect(p.dirname(f.path), p.join(tmp.path, 'sample_results'));
    }
    expect(
      files.markdown.readAsStringSync(),
      contains('sample_results/round_trip.svg'),
    );
  });

  test('writeReport skips charts without data and does not link them', () {
    final files = writeReport(
      fixturePath('legacy_classify.json'),
      outDir: tmp.path,
    );
    expect(
      files.skipped,
      containsAll(['round_trip.svg', 'jank.svg', 'speedup.svg']),
    );
    expect(files.charts.map((f) => p.basename(f.path)), ['classify_split.svg']);
    final md = files.markdown.readAsStringSync();
    expect(md, contains('legacy_classify/classify_split.svg'));
    expect(md, isNot(contains('round_trip.svg')));
  });

  test('running twice gives the same files', () {
    writeReport(fixturePath('sample_results.json'), outDir: tmp.path);
    final first = File(p.join(tmp.path, 'sample_results.md'))
        .readAsStringSync();
    writeReport(fixturePath('sample_results.json'), outDir: tmp.path);
    expect(
      File(p.join(tmp.path, 'sample_results.md')).readAsStringSync(),
      first,
    );
  });

  group('cli', () {
    test('succeeds and lists what it wrote', () {
      final out = StringBuffer();
      final code = runReport([
        fixturePath('sample_results.json'),
        '--out',
        tmp.path,
      ], out: out);
      expect(code, 0);
      expect(out.toString(), contains('sample_results.md'));
      expect(out.toString(), contains('round_trip.svg'));
    });

    test('exit 1 for a missing file', () {
      final err = StringBuffer();
      expect(
        runReport([p.join(tmp.path, 'nope.json'), '-o', tmp.path], err: err),
        1,
      );
      expect(err.toString(), contains('not found'));
    });

    test('exit 1 for a file that is not results', () {
      final bad = File(p.join(tmp.path, 'bad.json'))
        ..writeAsStringSync('{"schema": 9}');
      final err = StringBuffer();
      expect(runReport([bad.path, '-o', tmp.path], err: err), 1);
      expect(err.toString(), contains('Unsupported results schema'));
    });

    test('exit 2 for bad usage, 0 for --help', () {
      expect(runReport([], err: StringBuffer()), 2);
      expect(runReport(['a', 'b'], err: StringBuffer()), 2);
      expect(runReport(['--nope'], err: StringBuffer()), 2);
      final out = StringBuffer();
      expect(runReport(['--help'], out: out), 0);
      expect(out.toString(), contains('Usage: dart run tool/bin/report.dart'));
    });
  });
}
