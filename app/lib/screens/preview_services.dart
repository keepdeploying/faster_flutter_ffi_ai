// Stand-ins for the real bridges, so every screen runs (and is screenshotted)
// before the native pieces exist. Nothing here talks to native code.
//
// Two modes. Live: real clock, light real work, and a frame meter that reads
// the engine's frame timings. Deterministic: pass a [ManualClock] and every
// fake advances it by a modelled cost, so a test gets the same numbers every
// run.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../app_services.dart';
import '../bridges/bridge.dart';

/// A clock the fakes advance by hand.
class ManualClock {
  int micros = 0;

  void advance(num us) => micros += us.round();

  int call() => micros;
}

/// The last [capacity] frame times, newest last. One list is reused and the
/// listeners are told after every push, so the pulse strip allocates nothing.
class FrameTimeBuffer extends ChangeNotifier
    implements ValueListenable<List<double>> {
  FrameTimeBuffer({this.capacity = 240, Iterable<double> initial = const []}) {
    _values.addAll(initial);
  }

  final int capacity;
  final List<double> _values = <double>[];

  @override
  List<double> get value => _values;

  void push(double ms) {
    if (_values.length >= capacity) _values.removeAt(0);
    _values.add(ms);
    notifyListeners();
  }
}

class _Counter extends ChangeNotifier implements ValueListenable<int> {
  _Counter();
  int _value = 0;

  @override
  int get value => _value;

  void set(int v) {
    if (v == _value) return;
    _value = v;
    notifyListeners();
  }
}

/// Reads frame timings from the engine, the same source the real meter uses.
class PreviewFrameMeter {
  PreviewFrameMeter({this.budgetMs = 16.7});

  final double budgetMs;
  final FrameTimeBuffer buffer = FrameTimeBuffer();
  final _Counter _jank = _Counter();

  ValueListenable<List<double>> get frameTimes => buffer;
  ValueListenable<int> get jankCount => _jank;

  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  void _onTimings(List<FrameTiming> timings) {
    var jank = _jank.value;
    for (final t in timings) {
      final ms = t.totalSpan.inMicroseconds / 1000;
      if (ms > budgetMs) jank++;
      buffer.push(ms);
    }
    _jank.set(jank);
  }

  void dispose() {
    if (_started) SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    buffer.dispose();
    _jank.dispose();
  }
}

/// A fixed, readable pulse for tests and screenshots: steady frames with a few
/// hitches over the budget.
FrameTimeBuffer samplePulse({int count = 80}) {
  final buffer = FrameTimeBuffer(capacity: 240);
  final rnd = math.Random(7);
  for (var i = 0; i < count; i++) {
    var ms = 6.5 + rnd.nextDouble() * 4.5;
    if (i == 22 || i == 23) ms = 21 + rnd.nextDouble() * 4;
    if (i == 47) ms = 36;
    if (i == 61) ms = 19.5;
    if (i == 62) ms = 28;
    buffer._values.add(ms);
  }
  return buffer;
}

// -- Payload bridges ----------------------------------------------------------

class PreviewPayloadBridge implements PayloadBridge {
  PreviewPayloadBridge(this.kind, {this.clock});

  @override
  final BridgeKind kind;
  final ManualClock? clock;

  final Expando<int> _sums = Expando<int>('checksum');
  var _calls = 0;

  /// Modelled cost in microseconds: a fixed part per call plus a part per byte,
  /// from "encode, copy and hop threads" down to "pass a pointer".
  static double modelledMicros(BridgeKind kind, int bytes) => switch (kind) {
    BridgeKind.methodChannel => 220 + bytes * 0.0030,
    BridgeKind.binaryChannel => 90 + bytes * 0.0012,
    BridgeKind.ffiCopy => 2.2 + bytes * 0.00025,
    BridgeKind.ffiLeaf => 0.45 + bytes * 0.00009,
    BridgeKind.ffiZeroCopy => 0.30 + bytes * 0.00006,
  };

  @override
  Future<void> warmUp(int maxBytes) async {}

  @override
  FutureOr<int> roundTrip(Uint8List payload) async {
    final sum = _sums[payload] ??= checksum(payload);
    final c = clock;
    if (c != null) {
      final jitter = 1 + 0.08 * math.sin(_calls++ * 1.7);
      c.advance(modelledMicros(kind, payload.length) * jitter);
    } else if (!kind.isFfi) {
      // Channels copy and hop: a real copy and a real event-loop turn.
      Uint8List.fromList(payload);
      await Future<void>.delayed(Duration.zero);
    }
    return sum;
  }

  @override
  void dispose() {}
}

// -- Classifiers --------------------------------------------------------------

class PreviewPreprocessor implements Preprocessor {
  const PreviewPreprocessor(this.label);

  @override
  final String label;

  @override
  Float32List preprocess(Frame frame, {int size = 224}) =>
      Float32List(size * size * 3);
}

class PreviewClassifier implements Classifier {
  PreviewClassifier(
    this.kind, {
    this.site = ExecutionSite.isolate,
    this.blockUiMs = 0,
  });

  @override
  final BridgeKind kind;
  final ExecutionSite site;

  /// Live preview only: hold the UI thread for this long per call, so choosing
  /// "UI thread" visibly breaks the pulse strip.
  final int blockUiMs;

  static const labels = [
    'tabby cat',
    'espresso',
    'park bench',
    'mountain bike',
    'umbrella',
    'lighthouse',
    'tennis ball',
    'goldfinch',
  ];

  @override
  Future<void> load() async {}

  @override
  Future<Classification> classify(Frame frame) async {
    if (blockUiMs > 0 && site == ExecutionSite.uiThread) {
      final sw = Stopwatch()..start();
      while (sw.elapsedMilliseconds < blockUiMs) {}
    }
    // Same model on both paths, so the same answer. Only the bridge differs.
    final h = frame.rgba.isEmpty
        ? 0
        : (frame.rgba[0] + frame.rgba[frame.rgba.length ~/ 2]);
    final index = h % labels.length;
    final confidence = 0.71 + (h % 25) / 100;
    final channel = !kind.isFfi;
    final pre = channel ? 3100 : 880;
    const inference = 8200;
    final bridge = channel ? 1900 : 140;
    return Classification(
      labelIndex: index,
      label: labels[index],
      confidence: confidence,
      totalMicros: pre + inference + bridge,
      preprocessMicros: pre,
      inferenceMicros: inference,
    );
  }

  @override
  void dispose() {}
}

/// A short looping set of synthetic frames: sky, ground and a coloured disc
/// that moves. Stands in for the bundled test frames.
Stream<Frame> previewFrames({
  Duration interval = const Duration(milliseconds: 120),
}) {
  final frames = _syntheticFrames();
  return Stream<Frame>.periodic(interval, (i) => frames[i % frames.length]);
}

List<Frame> _syntheticFrames() {
  const w = 128;
  const h = 96;
  const discs = [
    [0xEA, 0x43, 0x35],
    [0x34, 0xA8, 0x53],
    [0x42, 0x85, 0xF4],
    [0xF9, 0xAB, 0x00],
  ];
  return [
    for (var f = 0; f < 8; f++)
      () {
        final px = Uint8List(w * h * 4);
        final cx = 24 + f * 11.0;
        final cy = 52 - 10 * math.sin(f / 8 * math.pi * 2);
        final c = discs[f % discs.length];
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            final i = (y * w + x) * 4;
            final horizon = y > 62;
            var r = horizon ? 0xDD : 0xBF + (y * 0.5).round();
            var g = horizon ? 0xE6 : 0xD9 + (y * 0.3).round();
            var b = horizon ? 0xD3 : 0xF5;
            if (horizon && (x + y) % 16 < 3) {
              r = 0xC9;
              g = 0xD8;
              b = 0xC4;
            }
            final dx = x - cx, dy = y - cy;
            if (dx * dx + dy * dy < 20 * 20) {
              r = c[0];
              g = c[1];
              b = c[2];
            }
            px[i] = r.clamp(0, 255);
            px[i + 1] = g.clamp(0, 255);
            px[i + 2] = b.clamp(0, 255);
            px[i + 3] = 255;
          }
        }
        return Frame(rgba: px, width: w, height: h);
      }(),
  ];
}

// -- Text generation ----------------------------------------------------------

class PreviewTokenGenerator implements TokenGenerator {
  PreviewTokenGenerator({
    required this.label,
    required this.isRealModel,
    this.clock,
    this.tokenDelay = const Duration(milliseconds: 40),
    this.firstTokenDelay = const Duration(milliseconds: 90),
  });

  @override
  final String label;
  @override
  final bool isRealModel;
  final ManualClock? clock;
  final Duration tokenDelay;
  final Duration firstTokenDelay;

  bool _cancelled = false;

  static const _text =
      'A channel encodes the call, copies the bytes and hops threads, and '
      'every one of those steps shows up in the frame time. FFI passes a '
      'pointer and stays where it started, so the UI keeps its frames while '
      'the tokens stream in.';

  @override
  Future<void> load() async {}

  @override
  Stream<String> generate(String prompt, {int maxTokens = 128}) async* {
    _cancelled = false;
    final words = _text.split(' ');
    final c = clock;
    if (c != null) {
      c.advance(3100);
    } else {
      await Future<void>.delayed(firstTokenDelay);
    }
    for (var i = 0; i < maxTokens && i < words.length; i++) {
      if (_cancelled) return;
      if (i > 0) {
        if (c != null) {
          c.advance(25000);
        } else {
          await Future<void>.delayed(tokenDelay);
        }
      }
      yield i == 0 ? words[i] : ' ${words[i]}';
    }
  }

  @override
  Future<void> cancel() async => _cancelled = true;

  @override
  void dispose() {}
}

// -- Benchmark ----------------------------------------------------------------

class PreviewBenchmark implements BenchmarkHost {
  PreviewBenchmark({this.stepDelay = const Duration(milliseconds: 350)});

  final Duration stepDelay;

  @override
  List<String> get suites => const [
    'Round trip',
    'Preprocess',
    'Classify',
    'Jank',
    'Generate',
  ];

  static const _rows = <List<BenchRow>>[
    [
      BenchRow(
        suite: 'Round trip',
        name: 'Channel, 64 KB',
        p50Us: 212,
        p95Us: 260,
        p99Us: 410,
        kind: BridgeKind.methodChannel,
      ),
      BenchRow(
        suite: 'Round trip',
        name: 'FFI leaf, 64 KB',
        p50Us: 5.8,
        p95Us: 6.4,
        p99Us: 11.2,
        kind: BridgeKind.ffiLeaf,
      ),
    ],
    [
      BenchRow(
        suite: 'Preprocess',
        name: 'Dart',
        p50Us: 6200,
        p95Us: 6900,
        p99Us: 8400,
      ),
      BenchRow(
        suite: 'Preprocess',
        name: 'C over FFI',
        p50Us: 880,
        p95Us: 940,
        p99Us: 1300,
        kind: BridgeKind.ffiCopy,
      ),
    ],
    [
      BenchRow(
        suite: 'Classify',
        name: 'Channel, isolate',
        p50Us: 13200,
        p95Us: 14100,
        p99Us: 16900,
        kind: BridgeKind.methodChannel,
      ),
      BenchRow(
        suite: 'Classify',
        name: 'FFI, isolate',
        p50Us: 9220,
        p95Us: 9800,
        p99Us: 11000,
        kind: BridgeKind.ffiCopy,
      ),
    ],
    [
      BenchRow(
        suite: 'Jank',
        name: 'Channel, UI thread',
        p50Us: 21400,
        p95Us: 33000,
        p99Us: 49000,
        kind: BridgeKind.methodChannel,
      ),
      BenchRow(
        suite: 'Jank',
        name: 'FFI, isolate',
        p50Us: 8100,
        p95Us: 9000,
        p99Us: 12200,
        kind: BridgeKind.ffiCopy,
      ),
    ],
    [
      BenchRow(
        suite: 'Generate',
        name: 'Demo generator',
        p50Us: 3100,
        p95Us: 3300,
        p99Us: 3900,
      ),
    ],
  ];

  @override
  Stream<BenchProgress> run() async* {
    for (var i = 0; i < suites.length; i++) {
      yield BenchProgress(suite: suites[i], fraction: 0);
      if (stepDelay > Duration.zero) await Future<void>.delayed(stepDelay);
      yield BenchProgress(suite: suites[i], fraction: 0.5);
      if (stepDelay > Duration.zero) await Future<void>.delayed(stepDelay);
      yield BenchProgress(suite: suites[i], fraction: 1, rows: _rows[i]);
    }
  }

  @override
  Future<String> save() async {
    const path = '/documents/results/2026-10-14_preview.json';
    debugPrint('FFB_RESULTS_PATH=$path');
    return path;
  }

  @override
  Future<void> share() async {}
}

// -- Wiring -------------------------------------------------------------------

/// Builds [AppServices] from the fakes above. Pass a [clock] for numbers that
/// repeat exactly, and [frameTimes] / [jankCount] to pin the pulse strip.
class PreviewServices extends StatefulWidget {
  const PreviewServices({
    super.key,
    required this.child,
    this.clock,
    this.frameTimes,
    this.jankCount,
    this.stepDelay = const Duration(milliseconds: 350),
    this.debugBuild,
  });

  final Widget child;
  final ManualClock? clock;
  final ValueListenable<List<double>>? frameTimes;
  final ValueListenable<int>? jankCount;
  final Duration stepDelay;
  final bool? debugBuild;

  @override
  State<PreviewServices> createState() => _PreviewServicesState();
}

class _PreviewServicesState extends State<PreviewServices> {
  PreviewFrameMeter? _meter;
  late final List<PayloadBridge> _bridges;
  late final Map<BridgeKind, Classifier> _classifiers;
  late final List<TokenGenerator> _generators;

  @override
  void initState() {
    super.initState();
    final clock = widget.clock;
    if (widget.frameTimes == null || widget.jankCount == null) {
      _meter = PreviewFrameMeter()..start();
    }
    _bridges = [
      for (final k in BridgeKind.values) PreviewPayloadBridge(k, clock: clock),
    ];
    _classifiers = {
      BridgeKind.methodChannel: PreviewClassifier(BridgeKind.methodChannel),
      BridgeKind.ffiCopy: PreviewClassifier(BridgeKind.ffiCopy),
    };
    _generators = [
      PreviewTokenGenerator(
        label: 'Demo generator',
        isRealModel: false,
        clock: clock,
      ),
      PreviewTokenGenerator(
        label: 'LLM',
        isRealModel: true,
        clock: clock,
        tokenDelay: const Duration(milliseconds: 90),
        firstTokenDelay: const Duration(milliseconds: 320),
      ),
    ];
  }

  @override
  void dispose() {
    _meter?.dispose();
    for (final b in _bridges) {
      b.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final clock = widget.clock;
    return AppServices(
      payloadBridges: _bridges,
      classifiers: _classifiers,
      preprocessors: const [
        PreviewPreprocessor('Dart'),
        PreviewPreprocessor('C over FFI'),
      ],
      generators: _generators,
      frameTimes: widget.frameTimes ?? _meter!.frameTimes,
      jankCount: widget.jankCount ?? _meter!.jankCount,
      frames: clock == null
          ? previewFrames
          : () => previewFrames(interval: const Duration(milliseconds: 100)),
      benchmark: PreviewBenchmark(
        stepDelay: clock == null ? widget.stepDelay : Duration.zero,
      ),
      classifierAt: (kind, site) => PreviewClassifier(
        kind,
        site: site,
        blockUiMs: clock == null ? 26 : 0,
      ),
      nowMicros: clock?.call ?? _liveClock,
      debugBuild: widget.debugBuild ?? kDebugMode,
      child: widget.child,
    );
  }
}

final Stopwatch _live = Stopwatch()..start();
int _liveClock() => _live.elapsedMicroseconds;
