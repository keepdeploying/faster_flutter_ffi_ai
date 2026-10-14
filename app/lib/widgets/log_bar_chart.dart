import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/theme.dart';
import '../theme/tokens.dart';
import 'format.dart';

class LogBar {
  const LogBar({
    required this.label,
    required this.icon,
    required this.color,
    required this.valueUs,
  });

  final String label;
  final IconData icon;
  final Color color;

  /// Null until the first samples arrive; the bar then shows a quiet track.
  final double? valueUs;
}

/// Horizontal bars on a log scale. Each gridline is ten times the one before,
/// so a bar twice as long is not twice as slow but ten times, which is what the
/// bridge race needs to show: the bridges differ by orders of magnitude.
class LogBarChart extends StatelessWidget {
  const LogBarChart({
    super.key,
    required this.bars,
    this.minUs = 0.1,
    this.maxUs = 100000,
  });

  final List<LogBar> bars;
  final double minUs;
  final double maxUs;

  double _fraction(double us) {
    final lo = math.log(minUs) / math.ln10;
    final hi = math.log(maxUs) / math.ln10;
    final v = math.log(us.clamp(minUs, maxUs)) / math.ln10;
    return ((v - lo) / (hi - lo)).clamp(0.0, 1.0);
  }

  List<double> get _ticks {
    final out = <double>[];
    var t = 1.0;
    while (t <= maxUs) {
      if (t >= minUs) out.add(t);
      t *= 10;
    }
    return out;
  }

  /// Units only where they change, so the labels stay short enough not to
  /// touch: 1 µs, 10, 100, 1 ms, 10, 100.
  static String _tickLabel(double us) {
    if (us == 1) return '1 µs';
    if (us == 1000) return '1 ms';
    return us < 1000 ? us.toStringAsFixed(0) : (us / 1000).toStringAsFixed(0);
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label:
          'Bridge race on a log scale. ${[for (final b in bars) '${b.label} ${b.valueUs == null ? 'waiting' : formatMicros(b.valueUs!)}'].join(', ')}',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _GridPainter(
                    fractions: [for (final t in _ticks) _fraction(t)],
                  ),
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final b in bars) ...[
                    _BarRow(bar: b, fraction: _fractionOf(b)),
                  ],
                ],
              ),
            ],
          ),
          const SizedBox(height: Space.s2),
          LayoutBuilder(
            builder: (context, c) {
              final ticks = _ticks;
              return SizedBox(
                height: 24,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (final t in ticks)
                      Positioned(
                        left: ((_fraction(t) * c.maxWidth) - 28).clamp(
                          0.0,
                          c.maxWidth - 56,
                        ),
                        width: 56,
                        top: 0,
                        child: Text(
                          _tickLabel(t),
                          textAlign: TextAlign.center,
                          style: AppText.quiet(AppText.monoSmall),
                          maxLines: 1,
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  double? _fractionOf(LogBar b) =>
      b.valueUs == null ? null : _fraction(b.valueUs!);
}

class _BarRow extends StatelessWidget {
  const _BarRow({required this.bar, required this.fraction});

  final LogBar bar;
  final double? fraction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(bar.icon, size: 24, color: bar.color),
              const SizedBox(width: Space.s2),
              Expanded(
                child: Text(
                  bar.label,
                  style: AppText.bodyStrong,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                bar.valueUs == null ? '–' : formatMicros(bar.valueUs!),
                style: AppText.monoBodyStrong,
              ),
            ],
          ),
          const SizedBox(height: Space.s1),
          LayoutBuilder(
            builder: (context, c) => Align(
              alignment: Alignment.centerLeft,
              child: Container(
                height: 12,
                width: fraction == null
                    ? 0
                    : math.max(4, fraction! * c.maxWidth),
                decoration: BoxDecoration(
                  color: bar.color,
                  borderRadius: const BorderRadius.horizontal(
                    right: Radius.circular(4),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter({required this.fractions});

  final List<double> fractions;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Palette.line
      ..strokeWidth = 1;
    for (final f in fractions) {
      final x = (f * size.width).roundToDouble() + 0.5;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) =>
      old.fractions.length != fractions.length;
}
