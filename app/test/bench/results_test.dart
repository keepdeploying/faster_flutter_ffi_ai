import 'dart:convert';
import 'dart:io';

import 'package:faster_flutter/bench/results.dart';
import 'package:flutter_test/flutter_test.dart';

// The example in docs/ARCHITECTURE.md, with the abbreviated `{}` objects filled
// in and the classify time split under the key `overhead` (the example uses
// `bridge` twice in one object, which JSON cannot hold).
const _stats =
    '{"p50Us": 0.4, "p95Us": 0.6, "p99Us": 1.1, "meanUs": 0.5, "minUs": 0.3, "maxUs": 12.0}';

const _example =
    '''
{
  "schema": 1,
  "createdAt": "2026-10-14T10:00:00Z",
  "device": {"platform": "android", "model": "Pixel 8", "os": "16", "abi": "arm64-v8a"},
  "flutter": "3.47.6",
  "buildMode": "profile",
  "suites": [
    {"suite": "round_trip", "bridge": "ffiLeaf", "payloadBytes": 1024,
     "warmup": 200, "runs": 2000, "stats": $_stats},
    {"suite": "preprocess", "impl": "c", "runs": 500, "stats": $_stats},
    {"suite": "classify", "bridge": "ffiCopy", "site": "isolate", "runs": 300,
     "total": $_stats, "preprocess": $_stats, "inference": $_stats, "overhead": $_stats},
    {"suite": "jank", "bridge": "methodChannel", "site": "uiThread", "seconds": 30,
     "frames": 1800, "jankyFrames": 42, "worstFrameMs": 61.2, "budgetMs": 16.7},
    {"suite": "generate", "generator": "demo", "tokens": 128,
     "firstTokenMs": 3.1, "tokensPerSec": 40.0, "jankyFrames": 0}
  ]
}
''';

void main() {
  test('the architecture example round trips unchanged', () {
    final original = jsonDecode(_example) as Map<String, Object?>;
    final results = BenchResults.fromJson(original);
    expect(results.suites, hasLength(5));
    expect(results.device.model, 'Pixel 8');
    expect(results.createdAt, DateTime.utc(2026, 10, 14, 10));
    // Through text as well, so number formatting is checked.
    final again = jsonDecode(results.toPrettyJson());
    expect(again, original);
  });

  test('the example with its abbreviated {} stats still parses', () {
    const text = '''
{"schema": 1, "createdAt": "2026-10-14T10:00:00Z",
 "device": {"platform": "android", "model": "Pixel 8", "os": "16", "abi": "arm64-v8a"},
 "flutter": "3.47.6", "buildMode": "profile",
 "suites": [
  {"suite": "preprocess", "impl": "c", "runs": 500, "stats": {}},
  {"suite": "classify", "bridge": "ffiCopy", "site": "isolate", "runs": 300,
   "total": {}, "preprocess": {}, "inference": {}, "bridge": {}}]}''';
    final r = BenchResults.fromJson(jsonDecode(text) as Map<String, Object?>);
    final classify = r.suites.last as ClassifyResult;
    // The example has two `bridge` keys in one object; JSON keeps the last
    // (the stats object), so the name is lost. That is why this model writes
    // the time split under `overhead`.
    expect(classify.bridge, '');
    expect(classify.overhead.p50Us, 0);
    expect(classify.total.p50Us, 0);
  });

  test('suite fields come through typed', () {
    final r = BenchResults.fromJson(
      jsonDecode(_example) as Map<String, Object?>,
    );
    final rt = r.suites[0] as RoundTripResult;
    expect(rt.bridge, 'ffiLeaf');
    expect(rt.stats.maxUs, 12.0);
    final jank = r.suites[3] as JankResult;
    expect(jank.jankyFrames, 42);
    expect(jank.budgetMs, 16.7);
    final gen = r.suites[4] as GenerateResult;
    expect(gen.tokensPerSec, 40.0);
  });

  test('unknown suites and schemas are rejected', () {
    expect(
      () => SuiteResult.fromJson({'suite': 'nope'}),
      throwsFormatException,
    );
    final json = jsonDecode(_example) as Map<String, Object?>;
    json['schema'] = 2;
    expect(() => BenchResults.fromJson(json), throwsFormatException);
  });

  test('fileName is <date>_<model-slug>.json', () {
    final r = BenchResults.fromJson(
      jsonDecode(_example) as Map<String, Object?>,
    );
    expect(r.fileName, '2026-10-14_pixel-8.json');
    expect(
      BenchResults.slugify('  Galaxy S24 Ultra (SM-S928B)! '),
      'galaxy-s24-ultra-sm-s928b',
    );
    expect(BenchResults.slugify('???'), 'device');
  });

  test('begin() captures the device and takes injected values', () {
    final r = BenchResults.begin(
      deviceModel: 'iPhone 15',
      now: DateTime.utc(2026, 1, 2, 3, 4, 5),
      buildMode: 'release',
      flutterVersion: '9.9.9',
    );
    expect(r.device.model, 'iPhone 15');
    expect(r.device.platform, Platform.operatingSystem);
    expect(r.device.os, Platform.operatingSystemVersion);
    expect(r.flutter, '9.9.9');
    expect(r.fileName, '2026-01-02_iphone-15.json');
    expect(r.toJson()['createdAt'], '2026-01-02T03:04:05Z');
  });

  test('the build mode under test is debug', () {
    expect(BenchResults.currentBuildMode(), 'debug');
    expect(BenchResults.begin().buildMode, 'debug');
  });

  test('save refuses a debug build and says to use --profile', () async {
    final dir = await Directory.systemTemp.createTemp('ffb_results_');
    final r = BenchResults.begin(deviceModel: 'x', buildMode: 'debug');
    await expectLater(
      r.save(dir),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('--profile'),
        ),
      ),
    );
    expect(dir.listSync(), isEmpty);
  });

  test('save writes pretty JSON and logs FFB_RESULTS_PATH', () async {
    final dir = await Directory.systemTemp.createTemp('ffb_results_');
    final results = BenchResults.fromJson(
      jsonDecode(_example) as Map<String, Object?>,
    );
    final lines = <String>[];
    final file = await results.save(
      Directory('${dir.path}/nested'),
      log: lines.add,
    );
    expect(file.path, endsWith('nested/2026-10-14_pixel-8.json'));
    expect(lines, ['FFB_RESULTS_PATH=${file.path}']);
    final text = await file.readAsString();
    expect(text, contains('\n  "schema": 1'));
    expect(jsonDecode(text), jsonDecode(_example));
    await dir.delete(recursive: true);
  });
}
