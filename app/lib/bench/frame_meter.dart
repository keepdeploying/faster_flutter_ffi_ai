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

class FrameMeter {
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

  int _frames = 0;
  int _janky = 0;
  double _worst = 0;

  bool _running = false;
  bool _keepFlowing = false;
  bool _disposed = false;

  /// The last [windowSize] frame totals in ms, oldest first. A new list is
  /// published per batch of frames, so listeners can keep the old one.
  ValueListenable<List<double>> get recent => _recent;

  /// Janky frames since the last [reset].
  ValueListenable<int> get jankCount => _jankCount;

  /// Frame budget in ms: janky means longer than this.
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
    if (ms > _budgetMs) _janky++;
    if (ms > _worst) _worst = ms;
    _window.add(ms);
    if (_window.length > windowSize) {
      _window.removeRange(0, _window.length - windowSize);
    }
  }

  void _publish() {
    if (_disposed) return;
    _recent.value = List<double>.unmodifiable(_window);
    _jankCount.value = _janky;
  }
}
