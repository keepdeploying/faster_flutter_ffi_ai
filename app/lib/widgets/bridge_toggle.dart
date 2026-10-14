import 'package:flutter/material.dart';

import '../bridges/bridge.dart';
import '../theme/bridge_style.dart';
import 'segmented.dart';

/// Picks a bridge. Each option wears its path colour: red for channels, green
/// for FFI, so the choice and the numbers that follow share one colour.
class BridgeToggle extends StatelessWidget {
  const BridgeToggle({
    super.key,
    required this.kinds,
    required this.selected,
    required this.onChanged,
  });

  final List<BridgeKind> kinds;
  final BridgeKind selected;
  final ValueChanged<BridgeKind>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Segmented<BridgeKind>(
      options: [
        for (final k in kinds)
          SegmentOption<BridgeKind>(
            value: k,
            label: BridgeStyle.of(k).label,
            icon: BridgeStyle.of(k).icon,
            color: BridgeStyle.of(k).color,
            tint: BridgeStyle.of(k).tint,
            semanticLabel: BridgeStyle.of(k).longLabel,
          ),
      ],
      selected: selected,
      onChanged: onChanged,
      stacked: kinds.length > 2,
    );
  }
}
