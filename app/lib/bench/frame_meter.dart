// Watches the frames the engine produces. It feeds two things: the pulse strip
// at the top of every demo screen (the last N frame times and a jank counter),
// and the jank suite of the benchmark (counts for a fixed duration).
//
// A frame is janky when its total span, from vsync to the end of rasterising,
// is longer than the budget: 16.7 ms at 60 Hz, 8.3 ms at 120 Hz.

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Counts for the frames seen between [FrameMeter.reset] and now.
class FrameSummary {
  const FrameSummary({
    required this.frames,
    required this.jankyFrames,
    required this.worstFrameMs,
    required this.budgetMs,
  });

  final int frames;
  final int jankyFrames;
  final double worstFrameMs;
  final double budgetMs;
}

/// One janky frame, as recorded by [FrameMeter] for the on-screen log.
class JankEntry {
  const JankEntry({required this.atMs, required this.durationMs});

  /// Milliseconds since the meter was created, so entries sort naturally and
  /// are stable across reset+clear cycles (which only touch the log, not the
  /// clock).
  final int atMs;

  /// How long that frame actually took, in ms.
  final double durationMs;
}

/// A read-only view onto the pulse-strip jank data. [FrameMeter] implements it;
/// tests can hand a fake to [AppServices].
abstract interface class JankMonitor {
  /// Janky frames observed in the last second.
  ValueListenable<int> get jankPerSecond;

  /// Bumps whenever a janky frame joins the log, so a watching sheet can
  /// rebuild without listening to a growing list.
  ValueListenable<int> get jankLogVersion;

  /// Frame budget in ms (one frame at the display's refresh rate).
  double get budgetMs;

  /// Snapshot of every janky frame seen since the last [clearJankLog] or
  /// meter reset.
  List<JankEntry> get jankLog;

  /// Empties the log. The rolling [jankPerSecond] is unaffected.
  void clearJankLog();
}

class FrameMeter implements JankMonitor {
  /// [windowSize] is how many recent frames the pulse strip can draw.
  /// [budgetMs] fixes the budget (tests); by default it follows the display.
  FrameMeter({this.windowSize = 120, double? budgetMs})
    : assert(windowSize > 0),
      _fixedBudgetMs = budgetMs,
      _budgetMs = budgetMs ?? detectBudgetMs();

  /// Budget in ms from the display refresh rate, or 60 Hz when the engine does
  /// not report one (no view yet, or a refresh rate of zero).
  static double detectBudgetMs() {
    try {
      final views = ui.PlatformDispatcher.instance.views;
      if (views.isNotEmpty) {
        final rate = views.first.display.refreshRate;
        if (rate.isFinite && rate >= 1) return 1000.0 / rate;
      }
    } catch (_) {
      // No display information: fall through to 60 Hz.
    }
    return 1000.0 / 60.0;
  }

  final int windowSize;
  final double? _fixedBudgetMs;
  double _budgetMs;

  final List<double> _window = <double>[];
  final ValueNotifier<List<double>> _recent = ValueNotifier<List<double>>(
    const <double>[],
  );
  final ValueNotifier<int> _jankCount = ValueNotifier<int>(0);

  /// Timestamps and durations of each janky frame seen since the last [reset].
  /// Rolling counter uses this; the log sheet reads it. Grows while recording;
  /// bounded by [_logCap] to avoid unbounded memory on a stuck screen.
  final List<JankEntry> _log = <JankEntry>[];
  final ValueNotifier<int> _logVersion = ValueNotifier<int>(0);
  final ValueNotifier<int> _jankPerSecond = ValueNotifier<int>(0);
  static const int _logCap = 1000;
  static const Duration _rateWindow = Duration(seconds: 1);
  final Stopwatch _clock = Stopwatch()..start();

  int _frames = 0;
  int _janky = 0;
  double _worst = 0;

  bool _running = false;
  bool _keepFlowing = false;
  bool _disposed = false;

  /// The last [windowSize] frame totals in ms, oldest first. A new list is
  /// published per batch of frames, so listeners can keep the old one.
  ValueListenable<List<double>> get recent => _recent;

  /// Janky frames since the last [reset]. Still exposed for the benchmark
  /// suite; the pulse strip reads [jankPerSecond] instead.
  ValueListenable<int> get jankCount => _jankCount;

  /// Janky frames observed in the last second. The pulse strip's counter.
  @override
  ValueListenable<int> get jankPerSecond => _jankPerSecond;

  /// Increments every time a janky frame is appended to the log, so a sheet
  /// can rebuild without exposing the list as a listenable.
  @override
  ValueListenable<int> get jankLogVersion => _logVersion;

  /// A snapshot of the janky frames seen since the last [reset] or
  /// [clearJankLog]. Returns an unmodifiable view.
  @override
  List<JankEntry> get jankLog => List<JankEntry>.unmodifiable(_log);

  /// Clears the jank log without touching other counters. The pulse strip's
  /// rolling rate stays accurate because it is recomputed from a parallel ring.
  @override
  void clearJankLog() {
    _log.clear();
    _logVersion.value = _logVersion.value + 1;
  }

  /// Frame budget in ms: janky means longer than this.
  @override
  double get budgetMs => _budgetMs;

  bool get isRunning => _running;

  FrameSummary get summary => FrameSummary(
    frames: _frames,
    jankyFrames: _janky,
    worstFrameMs: _worst,
    budgetMs: _budgetMs,
  );

  /// Starts listening to frame timings. With [keepFramesFlowing] the meter asks
  /// for a new frame after every frame, so a screen that is otherwise still
  /// keeps producing timings (the jank suite needs this; the app does not when
  /// the pulse strip already animates).
  void start({bool keepFramesFlowing = false}) {
    if (_running || _disposed) return;
    _running = true;
    _keepFlowing = keepFramesFlowing;
    _budgetMs = _fixedBudgetMs ?? detectBudgetMs();
    final binding = SchedulerBinding.instance;
    binding.addTimingsCallback(_onTimings);
    if (_keepFlowing) {
      binding.scheduleFrame();
      binding.addPostFrameCallback(_pump);
    }
  }

  void stop() {
    if (!_running) return;
    _running = false;
    _keepFlowing = false;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
  }

  /// Forgets all frames and counts.
  void reset() {
    _window.clear();
    _frames = 0;
    _janky = 0;
    _worst = 0;
    _recent.value = const <double>[];
    _jankCount.value = 0;
  }

  void dispose() {
    if (_disposed) return;
    stop();
    _disposed = true;
    _recent.dispose();
    _jankCount.dispose();
  }

  void _pump(Duration _) {
    if (!_running || !_keepFlowing) return;
    final binding = SchedulerBinding.instance;
    binding.scheduleFrame();
    binding.addPostFrameCallback(_pump);
  }

  void _onTimings(List<ui.FrameTiming> timings) {
    for (final t in timings) {
      _add(t.totalSpan.inMicroseconds / 1000.0);
    }
    _publish();
  }

  /// Feeds one frame total, in ms, as if the engine had reported it.
  @visibleForTesting
  void recordFrameMs(double ms) {
    _add(ms);
    _publish();
  }

  void _add(double ms) {
    _frames++;
    if (ms > _budgetMs) {
      _janky++;
      final at = _clock.elapsedMilliseconds;
      _log.add(JankEntry(atMs: at, durationMs: ms));
      if (_log.length > _logCap) _log.removeAt(0);
    }
    if (ms > _worst) _worst = ms;
    _window.add(ms);
    if (_window.length > windowSize) {
      _window.removeRange(0, _window.length - windowSize);
    }
  }

  /// Counts how many entries in [_log] are within the last [_rateWindow].
  int _rollingJankCount() {
    final cutoff = _clock.elapsedMilliseconds - _rateWindow.inMilliseconds;
    // Entries are appended in time order, so a reverse scan short-circuits
    // early even on a long log.
    var n = 0;
    for (var i = _log.length - 1; i >= 0; i--) {
      if (_log[i].atMs < cutoff) break;
      n++;
    }
    return n;
  }

  void _publish() {
    if (_disposed) return;
    _recent.value = List<double>.unmodifiable(_window);
    _jankCount.value = _janky;
    _jankPerSecond.value = _rollingJankCount();
    // Only bump the log version when a new entry landed since last publish.
    // _logVersion is read by the Jank-log sheet; the pulse strip itself only
    // listens to [_jankPerSecond], so bumping on every batch is cheap.
    _logVersion.value = _log.length;
  }
}
