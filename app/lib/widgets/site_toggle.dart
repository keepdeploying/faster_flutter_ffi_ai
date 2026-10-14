import 'package:flutter/material.dart';

import '../bridges/bridge.dart';
import '../theme/bridge_style.dart';
import 'segmented.dart';

/// Picks where the classifier runs: UI thread, isolate or native thread.
/// Sites that this build cannot run are shown but disabled.
class SiteToggle extends StatelessWidget {
  const SiteToggle({
    super.key,
    required this.selected,
    required this.onChanged,
    this.available = const {
      ExecutionSite.uiThread,
      ExecutionSite.isolate,
      ExecutionSite.nativeThread,
    },
  });

  final ExecutionSite selected;
  final ValueChanged<ExecutionSite>? onChanged;
  final Set<ExecutionSite> available;

  @override
  Widget build(BuildContext context) {
    return Segmented<ExecutionSite>(
      options: [
        for (final s in ExecutionSite.values)
          SegmentOption<ExecutionSite>(
            value: s,
            label: SiteStyle.of(s).label,
            icon: SiteStyle.of(s).icon,
            enabled: available.contains(s),
          ),
      ],
      selected: selected,
      onChanged: onChanged,
      stacked: true,
    );
  }
}
