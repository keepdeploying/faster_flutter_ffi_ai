import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The app icon's mark, drawn in code so it needs no image or SVG package: two
/// ink strokes with a gap between them and one green bolt that crosses the gap.
/// The geometry is the same 1024 grid as `assets/icon/icon.svg`.
class AppMark extends StatelessWidget {
  const AppMark({super.key, this.size = 48});

  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox.square(
      dimension: size,
      child: const CustomPaint(painter: _MarkPainter()),
    ),
  );
}

class _MarkPainter extends CustomPainter {
  const _MarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 1024;
    canvas.save();
    canvas.scale(k);
    final bar = Paint()..color = Palette.ink;
    for (final x in const [132.0, 588.0]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, 440, 304, 144),
          const Radius.circular(72),
        ),
        bar,
      );
    }
    const a = Offset(376, 800);
    const b = Offset(648, 224);
    // The paper-coloured outline cuts the strokes, so the bolt reads as one
    // shape even at 24 px.
    canvas.drawLine(
      a,
      b,
      Paint()
        ..color = Palette.paper
        ..strokeWidth = 208
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawLine(
      a,
      b,
      Paint()
        ..color = Palette.ffi
        ..strokeWidth = 144
        ..strokeCap = StrokeCap.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MarkPainter old) => false;
}
