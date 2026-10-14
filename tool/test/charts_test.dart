import 'package:faster_flutter_tool/faster_flutter_tool.dart';
import 'package:faster_flutter_tool/src/theme.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

import 'helpers.dart';

/// Parses [svg] as XML (a malformed chart throws) and returns the root.
XmlElement parse(String svg) => XmlDocument.parse(svg).rootElement;

void expectSlideChart(String svg, Results r) {
  final root = parse(svg);
  expect(root.name.local, 'svg');
  expect(root.getAttribute('viewBox'), '0 0 1600 900');
  expect(svg, contains('fill="#FFFFFF"')); // white page
  expect(svg, contains('#20344B')); // ink text
  // The source line: device, Flutter version, build mode, date.
  final texts = root.findAllElements('text').map((e) => e.innerText).toList();
  final source = texts.firstWhere((t) => t.contains('Flutter ${r.flutter}'));
  expect(source, contains(r.device.model));
  expect(source, contains('${r.buildMode} build'));
  expect(source, contains(r.date));
  // No legend box, no gradients, no shadows.
  expect(svg, isNot(contains('gradient')));
  expect(svg, isNot(contains('filter')));
}

void main() {
  final sample = loadFixture('sample_results.json');

  group('round_trip.svg', () {
    final svg = roundTripChart(sample)!;

    test('is a well-formed slide chart', () => expectSlideChart(svg, sample));

    test('draws one line per bridge in the deck colours', () {
      final paths = parse(svg).findAllElements('path').toList();
      expect(paths, hasLength(5));
      final strokes = paths.map((p) => p.getAttribute('stroke')).toSet();
      expect(strokes, {
        '#EA4335', '#FF7DAF', // channels
        '#1E7B34', '#34A853', '#5CDB6D', // FFI
      });
      // Zero-copy and copy are told apart by dashes, leaf and method are solid.
      final dashed = paths.where(
        (p) => p.getAttribute('stroke-dasharray') != null,
      );
      expect(dashed, hasLength(2));
    });

    test('labels every line at its end, without overlap', () {
      final root = parse(svg);
      final labels = root
          .findAllElements('text')
          .where((t) => t.findElements('tspan').length == 2)
          .toList();
      expect(labels, hasLength(5));
      final ys = labels.map((t) => double.parse(t.getAttribute('y')!)).toList()
        ..sort();
      for (var i = 1; i < ys.length; i++) {
        expect(ys[i] - ys[i - 1], greaterThanOrEqualTo(35.9));
      }
      final all = labels.map((t) => t.innerText).join(' ');
      expect(all, contains('MethodChannel'));
      expect(all, contains('FFI zero-copy'));
      expect(all, contains('38.0 ms'));
    });

    test('has a log axis with decade labels and the frame budget', () {
      final texts = parse(svg).findAllElements('text').map((e) => e.innerText);
      expect(texts, containsAll(['0.1 µs', '1 µs', '10 µs', '1 ms', '100 ms']));
      expect(texts, contains('one frame, 16.7 ms'));
      expect(svg, contains('stroke="#F9AB00"'));
    });

    test('leaves the budget out when every line is far below it', () {
      final fast = Results(
        createdAt: sample.createdAt,
        device: sample.device,
        flutter: sample.flutter,
        buildMode: sample.buildMode,
        suites: [
          RoundTrip(
            bridge: 'ffiLeaf',
            payloadBytes: 0,
            warmup: 1,
            runs: 1,
            stats: const Stats(
              p50Us: 0.3,
              p95Us: 0.4,
              p99Us: 0.5,
              meanUs: 0.3,
              minUs: 0.2,
              maxUs: 1,
            ),
          ),
          RoundTrip(
            bridge: 'ffiLeaf',
            payloadBytes: 1024,
            warmup: 1,
            runs: 1,
            stats: const Stats(
              p50Us: 0.5,
              p95Us: 0.6,
              p99Us: 0.7,
              meanUs: 0.5,
              minUs: 0.4,
              maxUs: 1,
            ),
          ),
        ],
      );
      final out = roundTripChart(fast)!;
      expect(out, isNot(contains('#F9AB00')));
      parse(out);
    });

    test(
      'a p50 of zero sits on the floor instead of breaking the log scale',
      () {
        final zero = Results(
          createdAt: sample.createdAt,
          device: sample.device,
          flutter: sample.flutter,
          buildMode: sample.buildMode,
          suites: [
            RoundTrip(
              bridge: 'ffiLeaf',
              payloadBytes: 0,
              warmup: 1,
              runs: 1,
              stats: const Stats(
                p50Us: 0,
                p95Us: 0,
                p99Us: 0,
                meanUs: 0,
                minUs: 0,
                maxUs: 0,
              ),
            ),
          ],
        );
        final out = roundTripChart(zero)!;
        expect(out, isNot(contains('NaN')));
        expect(out, isNot(contains('Infinity')));
        parse(out);
      },
    );

    test('is null without round trips', () {
      expect(roundTripChart(loadFixture('legacy_classify.json')), isNull);
    });
  });

  group('classify_split.svg', () {
    final svg = classifySplitChart(sample)!;

    test('is a well-formed slide chart', () => expectSlideChart(svg, sample));

    test('draws three segments per bar, bridge colour on the overhead', () {
      final root = parse(svg);
      final rects = root.findAllElements('rect').toList();
      String? fill(XmlElement e) => e.getAttribute('fill');
      expect(
        rects.where((e) => fill(e) == inkLight).length,
        greaterThanOrEqualTo(6),
      );
      expect(
        rects.where((e) => fill(e) == inkMid),
        hasLength(greaterThanOrEqualTo(6)),
      );
      expect(
        rects.where((e) => fill(e) == '#EA4335').length,
        greaterThanOrEqualTo(3),
      );
    });

    test('names the sites and prints the totals', () {
      final text = parse(svg)
          .findAllElements('text')
          .map((e) => e.innerText)
          .join('|');
      expect(text, contains('UI thread'));
      expect(text, contains('Isolate'));
      expect(text, contains('Native thread'));
      expect(text, contains('38.7 ms'));
    });

    test('copes with the first-draft schema and escapes the device name', () {
      final legacy = loadFixture('legacy_classify.json');
      final out = classifySplitChart(legacy)!;
      expect(out, contains('Fixture &lt;pad&gt; &amp; phone'));
      expect(out, contains('unknown bridge'));
      parse(out);
    });

    test('is null without classify results', () {
      expect(
        classifySplitChart(
          Results(
            createdAt: sample.createdAt,
            device: sample.device,
            flutter: '3',
            buildMode: 'profile',
            suites: [],
          ),
        ),
        isNull,
      );
    });
  });

  group('jank.svg', () {
    final svg = jankChart(sample)!;

    test('is a well-formed slide chart', () => expectSlideChart(svg, sample));

    test('has one bar per case with the janky count', () {
      final text = parse(svg)
          .findAllElements('text')
          .map((e) => e.innerText)
          .toList();
      expect(text.where((t) => t.contains('of 1,800')), hasLength(6));
      expect(text.any((t) => t.contains('412 of 1,800')), isTrue);
      expect(svg, contains('#F9AB00')); // the budget key
    });

    test('is null without jank results', () {
      expect(jankChart(loadFixture('legacy_classify.json')), isNull);
    });
  });

  group('speedup.svg', () {
    test('shows channel p50 divided by leaf p50 at the model input size', () {
      final s = findSpeedup(sample)!;
      expect(s.payloadBytes, 602112);
      expect(s.channelUs, 3100);
      expect(s.ffiUs, 36);
      expect(s.factor, closeTo(86.11, 0.01));
      final svg = speedupChart(sample)!;
      expectSlideChart(svg, sample);
      expect(svg, contains('86.1×'));
      expect(svg, contains('MethodChannel p50 ÷ FFI leaf p50'));
    });

    test('uses the closest payload when the exact size is missing', () {
      final r = Results(
        createdAt: sample.createdAt,
        device: sample.device,
        flutter: '3',
        buildMode: 'profile',
        suites: [
          for (final b in ['methodChannel', 'ffiLeaf'])
            for (final size in [1024, 65536])
              RoundTrip(
                bridge: b,
                payloadBytes: size,
                warmup: 1,
                runs: 1,
                stats: Stats(
                  p50Us: b == 'ffiLeaf' ? 2 : 20,
                  p95Us: 1,
                  p99Us: 1,
                  meanUs: 1,
                  minUs: 1,
                  maxUs: 1,
                ),
              ),
        ],
      );
      expect(findSpeedup(r)!.payloadBytes, 65536);
      expect(findSpeedup(r)!.factor, 10);
    });

    test('is null when a bridge or a value is missing', () {
      expect(speedupChart(loadFixture('legacy_classify.json')), isNull);
      final noLeaf = Results(
        createdAt: sample.createdAt,
        device: sample.device,
        flutter: '3',
        buildMode: 'profile',
        suites: [sample.roundTripOf('methodChannel', 602112)!],
      );
      expect(findSpeedup(noLeaf), isNull);
    });

    test('says so when FFI was not faster', () {
      final slow = Results(
        createdAt: sample.createdAt,
        device: sample.device,
        flutter: '3',
        buildMode: 'profile',
        suites: [
          for (final b in ['methodChannel', 'ffiLeaf'])
            RoundTrip(
              bridge: b,
              payloadBytes: 602112,
              warmup: 1,
              runs: 1,
              stats: Stats(
                p50Us: b == 'ffiLeaf' ? 50 : 40,
                p95Us: 1,
                p99Us: 1,
                meanUs: 1,
                minUs: 1,
                maxUs: 1,
              ),
            ),
        ],
      );
      final svg = speedupChart(slow)!;
      expect(svg, contains('0.80×'));
      expect(svg, contains('not faster'));
    });
  });

  test('onColor picks the readable text colour', () {
    expect(onColor('#20344B'), '#FFFFFF');
    expect(onColor('#C3CAD2'), '#20344B');
    expect(contrast('#FFFFFF', '#000000'), closeTo(21, 0.01));
  });
}
