// Runs the benchmark suites. It depends only on the interfaces in
// lib/bridges/bridge.dart, never on a concrete bridge, so the same code times
// a method channel, an FFI leaf call or a fake.
//
// Honest-number rules built in here: warm up before measuring, verify the
// checksum on every call, report percentiles, and with `repeats` keep the run
// with the median p50.

import 'dart:async';
import 'dart:typed_data';

import '../bridges/bridge.dart';
import 'frame_meter.dart';
import 'results.dart';
import 'stats.dart';
import 'stopwatch.dart';

/// Where a running suite is. Sent on [BenchmarkRunner.progress].
class BenchProgress {
  const BenchProgress({
    required this.suite,
    required this.done,
    required this.total,
    this.repeat = 1,
    this.repeats = 1,
    this.message = '',
  });

  /// The schema's suite name, for example `round_trip`.
  final String suite;

  /// Measured steps finished, over all repeats.
  final int done;
  final int total;

  /// Which repeat is running (1-based) and how many there are.
  final int repeat;
  final int repeats;
  final String message;

  double get fraction => total <= 0 ? 1.0 : (done / total).clamp(0.0, 1.0);
  bool get isDone => done >= total;
}

/// Thrown by a suite after [BenchmarkRunner.cancel].
class BenchCancelled implements Exception {
  const BenchCancelled();
  @override
  String toString() => 'BenchCancelled: the benchmark was cancelled';
}

/// A bridge returned a checksum that differs from the one computed in Dart. The
/// numbers of a bridge that corrupts data are worthless, so this stops the run.
class ChecksumMismatch implements Exception {
  const ChecksumMismatch({
    required this.bridge,
    required this.expected,
    required this.actual,
    required this.payloadBytes,
  });

  final BridgeKind bridge;
  final int expected;
  final int actual;
  final int payloadBytes;

  @override
  String toString() =>
      'ChecksumMismatch: ${bridge.name} returned $actual for a '
      '$payloadBytes byte payload, expected $expected';
}

class BenchmarkRunner {
  final StreamController<BenchProgress> _progress =
      StreamController<BenchProgress>.broadcast();
  bool _cancelled = false;
  bool _disposed = false;

  /// Progress of the running suite. Broadcast: late listeners miss old events.
  Stream<BenchProgress> get progress => _progress.stream;

  bool get isCancelled => _cancelled;

  /// Asks the running suite to stop at its next step. It then throws
  /// [BenchCancelled]. The flag stays set until [reset].
  void cancel() => _cancelled = true;

  /// Clears a cancel so the runner can start suites again.
  void reset() => _cancelled = false;

  void dispose() {
    _disposed = true;
    _progress.close();
  }

  /// The payload every round trip uses: the same bytes on every bridge.
  static Uint8List makePayload(int bytes) {
    final p = Uint8List(bytes);
    for (var i = 0; i < bytes; i++) {
      p[i] = (i * 31 + 7) & 0xFF;
    }
    return p;
  }

  // ---------------------------------------------------------------- round trip

  /// Round trips of [payloadBytes] over [bridge]: [warmup] unmeasured calls,
  /// then [runs] measured ones. Every call, warm-up included, is checked
  /// against [checksum] and throws [ChecksumMismatch] on a difference.
  Future<RoundTripResult> roundTrip(
    PayloadBridge bridge, {
    required int payloadBytes,
    int warmup = 200,
    int runs = 2000,
    int repeats = 1,
  }) async {
    _begin();
    final payload = makePayload(payloadBytes);
    final expected = checksum(payload);
    await bridge.warmUp(payloadBytes);

    Future<double> one() async {
      final timed = await timeFutureOr<int>(() => bridge.roundTrip(payload));
      if (timed.value != expected) {
        throw ChecksumMismatch(
          bridge: bridge.kind,
          expected: expected,
          actual: timed.value,
          payloadBytes: payloadBytes,
        );
      }
      return timed.micros;
    }

    final attempts = <RoundTripResult>[];
    for (var r = 1; r <= repeats; r++) {
      for (var i = 0; i < warmup; i++) {
        await one();
        await _checkpoint(i);
      }
      final samples = List<double>.filled(runs, 0);
      for (var i = 0; i < runs; i++) {
        samples[i] = await one();
        await _checkpoint(i);
        _emit('round_trip', bridge.kind.name, r, repeats, i + 1, runs);
      }
      attempts.add(
        RoundTripResult(
          bridge: bridge.kind.name,
          payloadBytes: payloadBytes,
          warmup: warmup,
          runs: runs,
          stats: LatencyStats.fromSamples(samples),
        ),
      );
    }
    return medianBy<RoundTripResult>(attempts, (a) => a.stats.p50Us);
  }

  // ---------------------------------------------------------------- preprocess

  /// Preprocesses [frame] [runs] times. [impl] names the implementation in the
  /// results file (default: the lower-cased [Preprocessor.label]).
  Future<PreprocessResult> preprocess(
    Preprocessor preprocessor,
    Frame frame, {
    int runs = 500,
    int warmup = 20,
    int size = 224,
    int repeats = 1,
    String? impl,
  }) async {
    _begin();
    final attempts = <PreprocessResult>[];
    for (var r = 1; r <= repeats; r++) {
      for (var i = 0; i < warmup; i++) {
        preprocessor.preprocess(frame, size: size);
        await _checkpoint(i);
      }
      final samples = List<double>.filled(runs, 0);
      for (var i = 0; i < runs; i++) {
        samples[i] = timeSync(() => preprocessor.preprocess(frame, size: size));
        await _checkpoint(i);
        _emit('preprocess', preprocessor.label, r, repeats, i + 1, runs);
      }
      attempts.add(
        PreprocessResult(
          impl: impl ?? preprocessor.label.toLowerCase(),
          runs: runs,
          stats: LatencyStats.fromSamples(samples),
        ),
      );
    }
    return medianBy<PreprocessResult>(attempts, (a) => a.stats.p50Us);
  }

  // ------------------------------------------------------------------ classify

  /// Classifies [frames] in turn, [runs] times. The caller has called
  /// [Classifier.load]. The time split (total, preprocess, inference, bridge)
  /// is the one each [Classification] reports. [site] only labels the result:
  /// the caller decides where the classifier runs.
  Future<ClassifyResult> classify(
    Classifier classifier,
    List<Frame> frames, {
    int runs = 100,
    int warmup = 5,
    ExecutionSite site = ExecutionSite.uiThread,
    int repeats = 1,
  }) async {
    if (frames.isEmpty) {
      throw ArgumentError.value(frames, 'frames', 'must not be empty');
    }
    _begin();
    final attempts = <ClassifyResult>[];
    for (var r = 1; r <= repeats; r++) {
      for (var i = 0; i < warmup; i++) {
        await classifier.classify(frames[i % frames.length]);
        await _checkpoint(i);
      }
      final total = List<double>.filled(runs, 0);
      final pre = List<double>.filled(runs, 0);
      final inf = List<double>.filled(runs, 0);
      final bridge = List<double>.filled(runs, 0);
      for (var i = 0; i < runs; i++) {
        final c = await classifier.classify(frames[i % frames.length]);
        total[i] = c.totalMicros.toDouble();
        pre[i] = c.preprocessMicros.toDouble();
        inf[i] = c.inferenceMicros.toDouble();
        bridge[i] = c.bridgeMicros.toDouble();
        await _checkpoint(i);
        _emit('classify', classifier.kind.name, r, repeats, i + 1, runs);
      }
      attempts.add(
        ClassifyResult(
          bridge: classifier.kind.name,
          site: site.name,
          runs: runs,
          total: LatencyStats.fromSamples(total),
          preprocess: LatencyStats.fromSamples(pre),
          inference: LatencyStats.fromSamples(inf),
          overhead: LatencyStats.fromSamples(bridge),
        ),
      );
    }
    return medianBy<ClassifyResult>(attempts, (a) => a.total.p50Us);
  }

  // ---------------------------------------------------------------------- jank

  /// Calls [work] over and over for [duration] while [meter] counts frames.
  /// One call of [work] is one unit (classify one frame, one round trip). The
  /// loop yields to the event loop between calls, so a [work] that blocks the UI
  /// thread shows up as janky frames and a [work] that runs elsewhere does not.
  /// With `repeats` the repeat with the median janky-frame count is kept.
  ///
  /// [meter] defaults to a new [FrameMeter]. [keepFramesFlowing] asks the engine
  /// for frames even when nothing animates; tests turn it off.
  Future<JankResult> jank({
    required String bridge,
    required ExecutionSite site,
    required Duration duration,
    required FutureOr<void> Function() work,
    FrameMeter? meter,
    bool keepFramesFlowing = true,
    int repeats = 1,
  }) async {
    _begin();
    final m = meter ?? FrameMeter();
    final startedHere = !m.isRunning;
    final attempts = <JankResult>[];
    try {
      for (var r = 1; r <= repeats; r++) {
        m.reset();
        if (startedHere) m.start(keepFramesFlowing: keepFramesFlowing);
        final totalMs = duration.inMicroseconds / 1000.0;
        final t0 = nowMicros();
        var lastEmit = 0.0;
        while (true) {
          final elapsedMs = (nowMicros() - t0) / 1000.0;
          if (elapsedMs >= totalMs) break;
          await work();
          await Future<void>.delayed(Duration.zero);
          await _checkpoint(0);
          if (elapsedMs - lastEmit >= 100) {
            lastEmit = elapsedMs;
            _emitRaw(
              'jank',
              bridge,
              r,
              repeats,
              (elapsedMs + (r - 1) * totalMs).round(),
              (totalMs * repeats).round(),
            );
          }
        }
        final s = m.summary;
        attempts.add(
          JankResult(
            bridge: bridge,
            site: site.name,
            seconds: duration.inMicroseconds / 1e6,
            frames: s.frames,
            jankyFrames: s.jankyFrames,
            worstFrameMs: s.worstFrameMs,
            budgetMs: s.budgetMs,
          ),
        );
        if (startedHere) m.stop();
      }
    } finally {
      if (startedHere) m.stop();
      if (meter == null) m.dispose();
    }
    _emitRaw('jank', bridge, repeats, repeats, 1, 1);
    return medianBy<JankResult>(attempts, (a) => a.jankyFrames.toDouble());
  }

  // ------------------------------------------------------------------ generate

  /// Generates up to [maxTokens] tokens for [prompt].
  ///
  /// * `firstTokenMs`: from the call to the first token.
  /// * `tokensPerSec`: the decode rate, (tokens - 1) / time between the first
  ///   and the last token, so start-up cost does not hide in it. 0 when fewer
  ///   than two tokens arrive.
  /// * `jankyFrames`: from [meter] while the stream ran (0 without a meter).
  ///   A meter already running is left running; either way it is reset first.
  ///
  /// With `repeats` the repeat with the median tokens per second is kept.
  Future<GenerateResult> generate(
    TokenGenerator generator,
    String prompt, {
    int maxTokens = 128,
    FrameMeter? meter,
    int repeats = 1,
  }) async {
    _begin();
    final attempts = <GenerateResult>[];
    for (var r = 1; r <= repeats; r++) {
      final startedMeter = meter != null && !meter.isRunning;
      meter?.reset();
      if (startedMeter) meter.start();
      var tokens = 0;
      double? tFirst;
      var tLast = 0.0;
      final t0 = nowMicros();
      try {
        await for (final _ in generator.generate(
          prompt,
          maxTokens: maxTokens,
        )) {
          final now = nowMicros();
          tFirst ??= now;
          tLast = now;
          tokens++;
          if (_cancelled) {
            await generator.cancel();
            throw const BenchCancelled();
          }
          _emit('generate', generator.label, r, repeats, tokens, maxTokens);
        }
      } finally {
        if (startedMeter) meter.stop();
      }
      if (tokens == 0 || tFirst == null) {
        throw StateError('${generator.label} produced no tokens');
      }
      final spanSec = (tLast - tFirst) / 1e6;
      attempts.add(
        GenerateResult(
          generator: generator.isRealModel ? 'llm' : 'demo',
          tokens: tokens,
          firstTokenMs: (tFirst - t0) / 1000.0,
          tokensPerSec: tokens > 1 && spanSec > 0 ? (tokens - 1) / spanSec : 0,
          jankyFrames: meter?.summary.jankyFrames ?? 0,
        ),
      );
    }
    return medianBy<GenerateResult>(attempts, (a) => a.tokensPerSec);
  }

  // ------------------------------------------------------------------- helpers

  void _begin() {
    if (_cancelled) throw const BenchCancelled();
  }

  /// Throws if cancelled; every 64th step also yields to the event loop so the
  /// UI can draw and progress events can be delivered.
  Future<void> _checkpoint(int i) async {
    if (_cancelled) throw const BenchCancelled();
    if ((i & 63) == 63) {
      await Future<void>.delayed(Duration.zero);
      if (_cancelled) throw const BenchCancelled();
    }
  }

  /// Emits about 50 events per suite instead of one per run.
  void _emit(
    String suite,
    String what,
    int repeat,
    int repeats,
    int i,
    int runs,
  ) {
    final stride = runs <= 50 ? 1 : runs ~/ 50;
    if (i % stride != 0 && i != runs) return;
    _emitRaw(
      suite,
      what,
      repeat,
      repeats,
      (repeat - 1) * runs + i,
      runs * repeats,
    );
  }

  void _emitRaw(
    String suite,
    String what,
    int repeat,
    int repeats,
    int done,
    int total,
  ) {
    if (_disposed || _progress.isClosed || !_progress.hasListener) return;
    _progress.add(
      BenchProgress(
        suite: suite,
        done: done,
        total: total,
        repeat: repeat,
        repeats: repeats,
        message: what,
      ),
    );
  }
}
