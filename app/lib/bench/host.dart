// The full benchmark behind the "Run the benchmark" screen and the
// integration test. It runs every suite on the real bridges, in a fixed order,
// and writes one results file (schema 1, see docs/ARCHITECTURE.md).

import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../app_services.dart' as ui show BenchProgress, BenchRow, BenchmarkHost;
import '../app_services.dart' show ClassifierAt;
import '../bridges/bridge.dart';
import 'frame_meter.dart';
import 'results.dart';
import 'runner.dart';
import 'stats.dart';

/// How much each suite runs. [full] is for the numbers on the slides; [quick]
/// checks the wiring in about a minute.
class BenchConfig {
  const BenchConfig({
    required this.payloadSizes,
    required this.roundTripWarmup,
    required this.roundTripRuns,
    required this.preprocessRuns,
    required this.classifyRuns,
    required this.jankDuration,
    required this.generateTokens,
    required this.repeats,
  });

  /// 0 B, 1 KB, 64 KB, one 224x224x3 float tensor, one 1080p RGBA frame.
  static const sizes = [0, 1024, 65536, 602112, 8294400];

  static const full = BenchConfig(
    payloadSizes: sizes,
    roundTripWarmup: 200,
    roundTripRuns: 2000,
    preprocessRuns: 500,
    classifyRuns: 300,
    jankDuration: Duration(seconds: 30),
    generateTokens: 128,
    repeats: 3,
  );

  static const quick = BenchConfig(
    payloadSizes: sizes,
    roundTripWarmup: 10,
    roundTripRuns: 50,
    preprocessRuns: 20,
    classifyRuns: 10,
    jankDuration: Duration(seconds: 3),
    generateTokens: 16,
    repeats: 1,
  );

  final List<int> payloadSizes;
  final int roundTripWarmup;
  final int roundTripRuns;
  final int preprocessRuns;
  final int classifyRuns;
  final Duration jankDuration;
  final int generateTokens;
  final int repeats;

  /// Big payloads take long per call, so they get fewer runs.
  int runsFor(int bytes) => bytes >= 1 << 20
      ? (roundTripRuns ~/ 10).clamp(10, roundTripRuns)
      : roundTripRuns;
}

/// The cases the classify and jank suites compare, in the order of the talk.
const _cases = <(BridgeKind, ExecutionSite)>[
  (BridgeKind.methodChannel, ExecutionSite.uiThread),
  (BridgeKind.methodChannel, ExecutionSite.nativeThread),
  (BridgeKind.ffiCopy, ExecutionSite.uiThread),
  (BridgeKind.ffiCopy, ExecutionSite.isolate),
];

class RealBenchmark implements ui.BenchmarkHost {
  RealBenchmark({
    required this.payloadBridges,
    required this.preprocessors,
    required this.classifierAt,
    required this.generators,
    required this.frames,
    required this.meter,
    this.config = BenchConfig.full,
    this.deviceModel,
  });

  final List<PayloadBridge> payloadBridges;
  final List<Preprocessor> preprocessors;
  final ClassifierAt classifierAt;
  final List<TokenGenerator> generators;
  final Future<List<Frame>> Function() frames;
  final FrameMeter meter;
  final BenchConfig config;

  /// The phone model for the results file. Defaults to device_info_plus;
  /// tests pass their own.
  final Future<String> Function()? deviceModel;

  final BenchmarkRunner _runner = BenchmarkRunner();
  BenchResults? _results;
  String? _savedPath;

  /// The results of the last finished run, or null.
  BenchResults? get results => _results;

  @override
  List<String> get suites => const [
    'Round trip',
    'Preprocess',
    'Classify',
    'Jank',
    'Generate',
  ];

  @override
  Stream<ui.BenchProgress> run() async* {
    _runner.reset();
    _savedPath = null;
    final results = BenchResults.begin(
      deviceModel: await (deviceModel ?? _deviceModel)(),
    );
    final input = await frames();
    final c = config;

    // Round trip: every bridge, every payload size.
    var rows = <ui.BenchRow>[];
    final rtTotal = payloadBridges.length * c.payloadSizes.length;
    var done = 0;
    yield ui.BenchProgress(suite: suites[0], fraction: 0);
    for (final bridge in payloadBridges) {
      for (final bytes in c.payloadSizes) {
        final r = await _runner.roundTrip(
          bridge,
          payloadBytes: bytes,
          warmup: c.roundTripWarmup,
          runs: c.runsFor(bytes),
          repeats: c.repeats,
        );
        results.suites.add(r);
        rows.add(
          _row(
            suites[0],
            '${bridge.kind.label}, ${_size(bytes)}',
            r.stats,
            bridge.kind,
          ),
        );
        yield ui.BenchProgress(suite: suites[0], fraction: ++done / rtTotal);
      }
    }
    yield ui.BenchProgress(suite: suites[0], fraction: 1, rows: rows);

    // Preprocess: the same frame in Dart and in C.
    rows = [];
    done = 0;
    yield ui.BenchProgress(suite: suites[1], fraction: 0);
    for (final p in preprocessors) {
      final r = await _runner.preprocess(
        p,
        input.first,
        runs: c.preprocessRuns,
        repeats: c.repeats,
      );
      results.suites.add(r);
      rows.add(_row(suites[1], p.label, r.stats, null));
      yield ui.BenchProgress(
        suite: suites[1],
        fraction: ++done / preprocessors.length,
      );
    }
    yield ui.BenchProgress(suite: suites[1], fraction: 1, rows: rows);

    // Classify: the same frames through each bridge at each site.
    rows = [];
    done = 0;
    yield ui.BenchProgress(suite: suites[2], fraction: 0);
    for (final (kind, site) in _cases) {
      final classifier = classifierAt(kind, site);
      try {
        await classifier.load();
        final r = await _runner.classify(
          classifier,
          input,
          runs: c.classifyRuns,
          site: site,
          repeats: c.repeats,
        );
        results.suites.add(r);
        rows.add(_row(suites[2], _caseName(kind, site), r.total, kind));
      } finally {
        classifier.dispose();
      }
      yield ui.BenchProgress(
        suite: suites[2],
        fraction: ++done / _cases.length,
      );
    }
    yield ui.BenchProgress(suite: suites[2], fraction: 1, rows: rows);

    // Jank: classify frames back to back for a while and count slow frames.
    rows = [];
    done = 0;
    yield ui.BenchProgress(suite: suites[3], fraction: 0);
    for (final (kind, site) in _cases) {
      final classifier = classifierAt(kind, site);
      try {
        await classifier.load();
        var i = 0;
        final r = await _runner.jank(
          bridge: kind.name,
          site: site,
          duration: c.jankDuration,
          meter: meter,
          repeats: c.repeats,
          work: () => classifier.classify(input[i++ % input.length]),
        );
        results.suites.add(r);
        final worstUs = r.worstFrameMs * 1000;
        rows.add(
          ui.BenchRow(
            suite: suites[3],
            name:
                '${_caseName(kind, site)}, ${r.jankyFrames} of ${r.frames} frames slow',
            p50Us: worstUs,
            p95Us: worstUs,
            p99Us: worstUs,
            kind: kind,
          ),
        );
      } finally {
        classifier.dispose();
      }
      yield ui.BenchProgress(
        suite: suites[3],
        fraction: ++done / _cases.length,
      );
    }
    yield ui.BenchProgress(suite: suites[3], fraction: 1, rows: rows);

    // Generate: the C demo generator always; the LLM when its model is there.
    rows = [];
    done = 0;
    yield ui.BenchProgress(suite: suites[4], fraction: 0);
    for (final g in generators) {
      try {
        await g.load();
      } on Object {
        // The LLM model is optional for a benchmark run (docs/LLM.md).
        if (g.isRealModel) continue;
        rethrow;
      }
      final r = await _runner.generate(
        g,
        'Explain in two sentences why on-device AI helps privacy.',
        maxTokens: c.generateTokens,
        meter: meter,
        repeats: c.repeats,
      );
      results.suites.add(r);
      final firstUs = r.firstTokenMs * 1000;
      rows.add(
        ui.BenchRow(
          suite: suites[4],
          name: '${g.label}, ${r.tokensPerSec.toStringAsFixed(1)} tokens/s',
          p50Us: firstUs,
          p95Us: firstUs,
          p99Us: firstUs,
        ),
      );
      yield ui.BenchProgress(
        suite: suites[4],
        fraction: ++done / generators.length,
      );
    }
    yield ui.BenchProgress(suite: suites[4], fraction: 1, rows: rows);

    _results = results;
  }

  /// Stops a run between two measurements.
  void cancel() => _runner.cancel();

  @override
  Future<String> save() async {
    final results = _results;
    if (results == null) throw StateError('Run the benchmark first.');
    final docs = await getApplicationDocumentsDirectory();
    final file = await results.save(Directory('${docs.path}/results'));
    return _savedPath = file.path;
  }

  @override
  Future<void> share() async {
    final path = _savedPath ?? await save();
    await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
  }

  void dispose() => _runner.dispose();

  static Future<String> _deviceModel() async {
    final info = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final a = await info.androidInfo;
      return '${a.manufacturer} ${a.model}';
    }
    if (Platform.isIOS) return (await info.iosInfo).modelName;
    return Platform.operatingSystem;
  }
}

ui.BenchRow _row(String suite, String name, LatencyStats s, BridgeKind? kind) =>
    ui.BenchRow(
      suite: suite,
      name: name,
      p50Us: s.p50Us,
      p95Us: s.p95Us,
      p99Us: s.p99Us,
      kind: kind,
    );

String _caseName(BridgeKind kind, ExecutionSite site) {
  final bridge = kind.isFfi ? 'FFI' : 'Channel';
  final where = switch (site) {
    ExecutionSite.uiThread => 'UI thread',
    ExecutionSite.isolate => 'isolate',
    ExecutionSite.nativeThread => 'native thread',
  };
  return '$bridge, $where';
}

String _size(int bytes) {
  if (bytes == 0) return '0 B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
