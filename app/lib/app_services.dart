// Everything the screens need from the outside world, handed down the widget
// tree. Screens never import a concrete bridge, so the same screens run on fakes
// in tests and on the real bridges on a phone.

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'bridges/bridge.dart';

/// Where frames for the classifier come from: bundled frames on a loop, or a
/// live camera. Each call starts a new stream; cancel the subscription to stop.
typedef FrameSource = Stream<Frame> Function();

/// A monotonic clock in microseconds. Screens time their own work with this
/// instead of reading the system clock, so tests can drive it by hand.
typedef MicrosClock = int Function();

/// Builds a classifier that runs [kind] at [site]. Null when the build can only
/// run one site, in which case the screens use [AppServices.classifiers].
typedef ClassifierAt = Classifier Function(
  BridgeKind kind,
  ExecutionSite site,
);

/// One row of the benchmark results table.
class BenchRow {
  const BenchRow({
    required this.suite,
    required this.name,
    required this.p50Us,
    required this.p95Us,
    required this.p99Us,
    this.kind,
  });

  /// `round_trip`, `preprocess`, `classify`, `jank` or `generate`.
  final String suite;

  /// What was measured, such as `FFI leaf, 64 KB`.
  final String name;
  final double p50Us;
  final double p95Us;
  final double p99Us;

  /// Set when the row belongs to a bridge, so the table can colour it.
  final BridgeKind? kind;
}

/// A step of a benchmark run: which suite is running, how far along, and the
/// rows that suite produced once it is done.
class BenchProgress {
  const BenchProgress({
    required this.suite,
    required this.fraction,
    this.rows = const [],
  });

  final String suite;

  /// 0 to 1.
  final double fraction;
  final List<BenchRow> rows;

  bool get done => fraction >= 1;
}

/// Runs the full benchmark. The real one lives in `lib/bench`; screens only see
/// this shape.
abstract interface class BenchmarkHost {
  /// Suite names in run order, so the screen can list them before it starts.
  List<String> get suites;

  /// Starts a run. Emits progress as suites advance and finish.
  Stream<BenchProgress> run();

  /// Writes `results/<date>_<model>.json` in app documents, prints
  /// `FFB_RESULTS_PATH=<path>` and returns the path.
  Future<String> save();

  /// Opens the system share sheet for the saved file.
  Future<void> share();
}

class AppServices extends InheritedWidget {
  const AppServices({
    super.key,
    required this.payloadBridges,
    required this.classifiers,
    required this.preprocessors,
    required this.generators,
    required this.frameTimes,
    required this.jankCount,
    required this.frames,
    required this.benchmark,
    this.classifierAt,
    this.nowMicros = _systemMicros,
    this.debugBuild = kDebugMode,
    required super.child,
  });

  final List<PayloadBridge> payloadBridges;
  final Map<BridgeKind, Classifier> classifiers;
  final List<Preprocessor> preprocessors;
  final List<TokenGenerator> generators;

  /// The last frames' durations in milliseconds, newest last. The pulse strip
  /// draws one tick per entry.
  final ValueListenable<List<double>> frameTimes;

  /// Frames over budget since the meter started.
  final ValueListenable<int> jankCount;

  final FrameSource frames;
  final BenchmarkHost benchmark;
  final ClassifierAt? classifierAt;
  final MicrosClock nowMicros;

  /// True in debug mode. Measurement screens then show a banner and the
  /// benchmark refuses to save.
  final bool debugBuild;

  static AppServices of(BuildContext context) {
    final s = context.dependOnInheritedWidgetOfExactType<AppServices>();
    assert(s != null, 'Wrap the app in AppServices.');
    return s!;
  }

  @override
  bool updateShouldNotify(AppServices old) =>
      payloadBridges != old.payloadBridges ||
      classifiers != old.classifiers ||
      preprocessors != old.preprocessors ||
      generators != old.generators ||
      frameTimes != old.frameTimes ||
      jankCount != old.jankCount ||
      frames != old.frames ||
      benchmark != old.benchmark ||
      classifierAt != old.classifierAt ||
      nowMicros != old.nowMicros ||
      debugBuild != old.debugBuild;
}

final Stopwatch _systemClock = Stopwatch()..start();
int _systemMicros() => _systemClock.elapsedMicroseconds;
