import 'package:flutter/material.dart';

import '../theme/theme.dart';
import '../theme/tokens.dart';
import 'format.dart';

/// One frame's time as a stacked bar: preprocess, bridge, inference. The bridge
/// segment wears the colour of the path (red channel, green FFI) because it is
/// the only part that changes when the bridge changes; the other two stay ink.
class TimeSplitBar extends StatelessWidget {
  const TimeSplitBar({
    super.key,
    required this.preprocessUs,
    required this.bridgeUs,
    required this.inferenceUs,
    required this.bridgeColor,
  });

  final double preprocessUs;
  final double bridgeUs;
  final double inferenceUs;
  final Color bridgeColor;

  static const _preprocessColor = Color(0x6B20344B); // ink 42%
  static const _inferenceColor = Palette.ink;

  @override
  Widget build(BuildContext context) {
    final parts = [
      _Part('Preprocess', preprocessUs, _preprocessColor),
      _Part('Bridge', bridgeUs, bridgeColor),
      _Part('Inference', inferenceUs, _inferenceColor),
    ];
    final total = parts.fold<double>(0, (a, p) => a + p.us);
    return Semantics(
      label:
          'Time split: ${parts.map((p) => '${p.name} ${formatMicros(p.us)}').join(', ')}',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(Radii.small),
            child: SizedBox(
              height: 40,
              child: LayoutBuilder(
                builder: (context, c) {
                  if (total <= 0) {
                    return const ColoredBox(color: Palette.line);
                  }
                  // Keep a sliver of every non-zero part visible: the bridge
                  // share is often under 1% and is the whole point.
                  const minWidth = 4.0;
                  final widths = [
                    for (final p in parts)
                      p.us <= 0
                          ? 0.0
                          : (p.us / total * c.maxWidth).clamp(
                              minWidth,
                              c.maxWidth,
                            ),
                  ];
                  final sum = widths.fold<double>(0, (a, b) => a + b);
                  final scale = sum > c.maxWidth ? c.maxWidth / sum : 1.0;
                  return Row(
                    children: [
                      for (var i = 0; i < parts.length; i++)
                        if (widths[i] > 0)
                          SizedBox(
                            width: widths[i] * scale,
                            child: ColoredBox(color: parts[i].color),
                          ),
                    ],
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: Space.s3),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final p in parts)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: p.color,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          const SizedBox(width: Space.s2),
                          Text(p.name, style: AppText.small),
                        ],
                      ),
                      const SizedBox(height: Space.s1),
                      Text(
                        formatMicros(p.us),
                        style: AppText.monoBodyStrong,
                        maxLines: 1,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Part {
  const _Part(this.name, this.us, this.color);
  final String name;
  final double us;
  final Color color;
}
