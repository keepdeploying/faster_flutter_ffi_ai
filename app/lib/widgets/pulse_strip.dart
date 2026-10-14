import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/theme.dart';
import '../theme/tokens.dart';

/// The one memorable element: a live strip that draws one thin tick per frame,
/// its height the frame time, against a dashed 16.7 ms budget line. Ticks over
/// budget turn channel red; the strip scrolls left. The jank counter sits at the
/// right end in large figures.
///
/// It must not cause the jank it measures, so painting is two `drawRawPoints`
/// calls for the ticks and one for the dashes, with buffers reused between
/// frames and the text laid out once.
///
/// With reduced motion on, the strip stops scrolling and sweeps instead: new
/// ticks overwrite old ones in place, like an oscilloscope. Values and the
/// counter keep updating.
class PulseStrip extends StatefulWidget {
  const PulseStrip({
    super.key,
    required this.frameTimes,
    required this.jankCount,
    this.budgetMs = 16.7,
    this.height = 160,
  });

  final ValueListenable<List<double>> frameTimes;
  final ValueListenable<int> jankCount;
  final double budgetMs;
  final double height;

  @override
  State<PulseStrip> createState() => _PulseStripState();
}

class _Bump extends ChangeNotifier {
  void bump() => notifyListeners();
}

class _PulseStripState extends State<PulseStrip>
    with SingleTickerProviderStateMixin {
  late _PulsePainter _painter;

  // A pulse strip that only repaints when a frame happens would stop drawing
  // when the app is idle, and then there would be no frames to draw. The ticker
  // asks for a frame at the display rate, so the strip reads like a real
  // performance overlay. Its paint is cheap enough not to move the numbers.
  late final Ticker _ticker;
  final _Bump _bump = _Bump();

  @override
  void initState() {
    super.initState();
    _painter = _PulsePainter(widget.frameTimes, widget.budgetMs, _bump);
    _ticker = createTicker((_) => _bump.bump());
  }

  @override
  void didUpdateWidget(PulseStrip old) {
    super.didUpdateWidget(old);
    if (old.frameTimes != widget.frameTimes ||
        old.budgetMs != widget.budgetMs) {
      _painter.dispose();
      _painter = _PulsePainter(widget.frameTimes, widget.budgetMs, _bump);
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _painter.dispose();
    _bump.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    _painter.reducedMotion = reduced;
    if (reduced && _ticker.isActive) {
      _ticker.stop();
    } else if (!reduced && !_ticker.isActive) {
      _ticker.start();
    }
    return RepaintBoundary(
      child: ValueListenableBuilder<int>(
        valueListenable: widget.jankCount,
        builder: (context, jank, _) => Semantics(
          container: true,
          label: 'Frame pulse strip',
          value: jank == 1 ? '1 janky frame' : '$jank janky frames',
          child: ExcludeSemantics(
            child: SizedBox(
              height: widget.height,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: Palette.line)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(left: Space.gutter),
                        child: CustomPaint(
                          painter: _painter,
                          size: Size.infinite,
                          isComplex: false,
                          willChange: true,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 136,
                      child: Padding(
                        padding: const EdgeInsets.only(
                          left: Space.s3,
                          right: Space.gutter,
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerRight,
                              child: Text(
                                '$jank',
                                style: AppText.monoDisplay.copyWith(
                                  color: jank > 0
                                      ? Palette.channel
                                      : Palette.ink,
                                ),
                              ),
                            ),
                            Text(
                              jank == 1 ? 'janky frame' : 'janky frames',
                              style: AppText.quiet(AppText.small),
                              maxLines: 1,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PulsePainter extends CustomPainter {
  _PulsePainter(this.frameTimes, this.budgetMs, Listenable ticks)
    : super(repaint: Listenable.merge([frameTimes, ticks])) {
    frameTimes.addListener(_onFrame);
  }

  final ValueListenable<List<double>> frameTimes;
  final double budgetMs;

  bool reducedMotion = false;

  static const double _pitch = 5;
  static const double _tickWidth = 3;
  static const double _topPad = 28;
  static const double _bottomPad = 8;

  /// The top of the strip is 2.4 times the budget, so the budget line sits a bit
  /// under the middle and a 40 ms hitch still fits.
  static const double _maxMs = 40;

  // Reused between paints.
  Float32List _okPts = Float32List(0);
  Float32List _badPts = Float32List(0);
  Float32List _dashPts = Float32List(0);
  double _dashWidth = -1;
  double _dashY = -1;

  final Paint _okPaint = Paint()
    ..color = Palette.ink
    ..strokeWidth = _tickWidth
    ..strokeCap = StrokeCap.butt;
  final Paint _badPaint = Paint()
    ..color = Palette.channel
    ..strokeWidth = _tickWidth
    ..strokeCap = StrokeCap.butt;
  final Paint _budgetPaint = Paint()
    ..color = Palette.budget
    ..strokeWidth = 2
    ..strokeCap = StrokeCap.butt;
  final Paint _basePaint = Paint()
    ..color = Palette.line
    ..strokeWidth = 1;
  final Paint _chipPaint = Paint()..color = Palette.paper;

  // Sweep mode state: a fixed ring of slots and the write head.
  List<double> _slots = const [];
  int _head = 0;

  late final TextPainter _label = TextPainter(
    text: TextSpan(
      text: '${budgetMs.toStringAsFixed(1)} ms',
      style: AppText.monoSmall.copyWith(color: Palette.quietText),
    ),
    textDirection: TextDirection.ltr,
  )..layout();

  void _onFrame() {
    if (!reducedMotion) return;
    final list = frameTimes.value;
    if (list.isEmpty || _slots.isEmpty) return;
    _slots[_head] = list.last;
    _head = (_head + 1) % _slots.length;
  }

  void dispose() {
    frameTimes.removeListener(_onFrame);
    _label.dispose();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final plotH = size.height - _topPad - _bottomPad;
    final baseY = size.height - _bottomPad;
    final cap = (size.width / _pitch).floor();
    if (cap <= 0 || plotH <= 0) return;

    double yFor(double ms) => baseY - (ms / _maxMs).clamp(0.0, 1.0) * plotH;

    // Baseline.
    canvas.drawLine(Offset(0, baseY), Offset(size.width, baseY), _basePaint);

    // Ticks.
    if (_okPts.length != cap * 4) {
      _okPts = Float32List(cap * 4);
      _badPts = Float32List(cap * 4);
    }
    var ok = 0;
    var bad = 0;
    void tick(int slotFromRight, double ms) {
      final x = size.width - (slotFromRight + 0.5) * _pitch;
      final y = yFor(ms);
      if (ms > budgetMs) {
        _badPts[bad++] = x;
        _badPts[bad++] = baseY;
        _badPts[bad++] = x;
        _badPts[bad++] = y;
      } else {
        _okPts[ok++] = x;
        _okPts[ok++] = baseY;
        _okPts[ok++] = x;
        _okPts[ok++] = y;
      }
    }

    if (reducedMotion) {
      if (_slots.length != cap) {
        _slots = List<double>.filled(cap, double.nan);
        _head = 0;
        final list = frameTimes.value;
        final start = list.length > cap ? list.length - cap : 0;
        for (var i = start; i < list.length; i++) {
          _slots[_head++] = list[i];
        }
        _head %= cap;
      }
      for (var i = 0; i < cap; i++) {
        final ms = _slots[i];
        if (ms.isNaN) continue;
        // Leave a two-slot gap ahead of the write head.
        final ahead = (i - _head) % cap;
        if (ahead < 2) continue;
        tick(cap - 1 - i, ms);
      }
    } else {
      final list = frameTimes.value;
      final n = list.length < cap ? list.length : cap;
      for (var i = 0; i < n; i++) {
        tick(n - 1 - i, list[list.length - n + i]);
      }
    }
    if (ok > 0) {
      canvas.drawRawPoints(
        ui.PointMode.lines,
        Float32List.sublistView(_okPts, 0, ok),
        _okPaint,
      );
    }
    if (bad > 0) {
      canvas.drawRawPoints(
        ui.PointMode.lines,
        Float32List.sublistView(_badPts, 0, bad),
        _badPaint,
      );
    }

    // Budget line: dashed, yellow, labelled.
    final by = yFor(budgetMs);
    if (_dashWidth != size.width || _dashY != by) {
      _dashWidth = size.width;
      _dashY = by;
      const dash = 10.0;
      const gap = 7.0;
      final count = (size.width / (dash + gap)).ceil();
      _dashPts = Float32List(count * 4);
      var k = 0;
      for (var i = 0; i < count; i++) {
        final x0 = i * (dash + gap);
        final x1 = (x0 + dash).clamp(0.0, size.width);
        _dashPts[k++] = x0;
        _dashPts[k++] = by;
        _dashPts[k++] = x1;
        _dashPts[k++] = by;
      }
    }
    canvas.drawRawPoints(ui.PointMode.lines, _dashPts, _budgetPaint);
    final lw = _label.width;
    final lh = _label.height;
    final labelRect = Rect.fromLTWH(0, by - lh - 4, lw + 8, lh + 2);
    canvas.drawRect(labelRect, _chipPaint);
    _label.paint(canvas, Offset(0, by - lh - 3));
  }

  @override
  bool shouldRepaint(_PulsePainter old) => old.budgetMs != budgetMs;
}
