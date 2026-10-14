import 'package:faster_flutter_tool/faster_flutter_tool.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  final sample = loadFixture('sample_results.json');
  final md = markdownReport(sample, sourceName: 'x.json', chartDir: 'x');

  test('starts with the device and date and names the source file', () {
    expect(md, startsWith('# Results: Fixture phone, 2026-10-14'));
    expect(md, contains('| Flutter | 3.47.6 |'));
    expect(md, contains('| Build mode | profile |'));
    expect(md, contains('| Source file | `x.json` |'));
    expect(md, isNot(contains('Warning')));
  });

  test('has a section for every suite type', () {
    for (final h in [
      '## Round trip',
      '## Preprocess',
      '## Classify',
      '## Jank',
      '## Generate',
    ]) {
      expect(md, contains(h));
    }
  });

  test('round trip tables carry p50, p95 and p99 per bridge and payload', () {
    expect(
      md,
      contains(
        '| Payload | MethodChannel | BinaryCodec channel | FFI + copy | FFI leaf | FFI zero-copy |',
      ),
    );
    expect(
      md,
      contains(
        '| 588 KB | MethodChannel | 3.10 ms | 4.96 ms | 6.94 ms | 2,000 |',
      ),
    );
    expect(md, contains('| 7.9 MB | FFI leaf | 540 µs |'));
    expect(
      md,
      contains(
        'At 588 KB, MethodChannel p50 is 3.10 ms and FFI leaf p50 is 36.0 µs: 86.1×',
      ),
    );
  });

  test('preprocess compares Dart and C', () {
    expect(md, contains('| Dart | 9.20 ms |'));
    expect(md, contains('| C (FFI) | 780 µs |'));
    expect(md, contains('11.8× (Dart divided by C)'));
  });

  test('classify splits total, preprocess, inference and overhead', () {
    expect(
      md,
      contains(
        '| Bridge | Site | Total | Preprocess | Inference | Overhead | Runs |',
      ),
    );
    expect(
      md,
      contains(
        '| MethodChannel | UI thread | 38.7 ms | 12.5 ms | 21.0 ms | 5.20 ms | 300 |',
      ),
    );
    expect(md, contains('| FFI + copy | Native thread |'));
  });

  test('jank lists frames, share and worst frame', () {
    expect(
      md,
      contains(
        '| MethodChannel | UI thread | 30 | 1,800 | 412 | 22.9% | 48.3 ms | 16.7 ms |',
      ),
    );
  });

  test('generate lists both generators', () {
    expect(md, contains('| C demo generator | 128 | 3.10 ms | 40.0 | 0 |'));
    expect(
      md,
      contains('| Qwen2.5 0.5B (llama.cpp) | 128 | 413 ms | 14.2 | 3 |'),
    );
  });

  test('links the charts that exist, and only those', () {
    expect(md, contains('![Round trip p50 per bridge](x/round_trip.svg)'));
    expect(md, contains('![Speed-up](x/speedup.svg)'));
    final some = markdownReport(
      sample,
      sourceName: 'x.json',
      chartDir: 'x',
      charts: {'jank.svg'},
    );
    expect(some, contains('x/jank.svg'));
    expect(some, isNot(contains('round_trip.svg')));
    final none = markdownReport(sample, sourceName: 'x.json');
    expect(none, isNot(contains('![')));
  });

  test('warns about a debug build', () {
    final debug = Results(
      createdAt: sample.createdAt,
      device: sample.device,
      flutter: '3.47.6',
      buildMode: 'debug',
      suites: [],
    );
    expect(
      markdownReport(debug, sourceName: 'd.json'),
      contains('> Warning: this file comes from a debug build'),
    );
  });

  test('a file with one suite only has that section', () {
    final legacy = markdownReport(
      loadFixture('legacy_classify.json'),
      sourceName: 'l.json',
    );
    expect(legacy, contains('## Classify'));
    expect(legacy, isNot(contains('## Round trip')));
    expect(legacy, contains('unknown bridge'));
  });
}
