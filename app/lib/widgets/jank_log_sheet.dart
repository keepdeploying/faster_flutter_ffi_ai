// Bottom sheet that lists every janky frame the current screen has seen so
// far, newest first, with a Clear button. Opened by tapping the counter on
// the pulse strip.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../app_services.dart' show JankEntry, JankMonitor;
import '../theme/theme.dart';
import '../theme/tokens.dart';

void showJankLogSheet(BuildContext context, JankMonitor monitor) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _JankLogSheet(monitor: monitor),
  );
}

class _JankLogSheet extends StatelessWidget {
  const _JankLogSheet({required this.monitor});

  final JankMonitor monitor;

  @override
  Widget build(BuildContext context) {
    final budget = monitor.budgetMs;
    return SafeArea(
      top: false,
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        builder: (context, controller) {
          return ValueListenableBuilder<int>(
            valueListenable: monitor.jankLogVersion,
            builder: (context, _, _) {
              // Snapshot per rebuild. Keep newest at the top.
              final log = monitor.jankLog.reversed.toList(growable: false);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      Space.gutter,
                      Space.s2,
                      Space.gutter,
                      Space.s3,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Jank log', style: AppText.heading),
                              const SizedBox(height: Space.s1),
                              Text(
                                'Frames over the ${budget.toStringAsFixed(1)} '
                                'ms budget since this screen opened.',
                                style: AppText.quiet(AppText.small),
                              ),
                            ],
                          ),
                        ),
                        if (log.isNotEmpty)
                          TextButton.icon(
                            onPressed: () => monitor.clearJankLog(),
                            icon: const Icon(
                              Symbols.delete_rounded,
                              size: 18,
                            ),
                            label: const Text('Clear'),
                          ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: log.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(Space.s5),
                              child: Text(
                                'No janky frames yet. Trigger some work on '
                                'the UI thread and come back.',
                                style: AppText.quiet(AppText.body),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          )
                        : ListView.separated(
                            controller: controller,
                            itemCount: log.length,
                            separatorBuilder: (_, _) =>
                                Divider(height: 1, color: Palette.line),
                            itemBuilder: (context, i) => _JankRow(
                              entry: log[i],
                              budgetMs: budget,
                            ),
                          ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _JankRow extends StatelessWidget {
  const _JankRow({required this.entry, required this.budgetMs});

  final JankEntry entry;
  final double budgetMs;

  @override
  Widget build(BuildContext context) {
    final over = entry.durationMs - budgetMs;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.gutter,
        vertical: Space.s2,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(
              _formatTimestamp(entry.atMs),
              style: AppText.monoSmall,
            ),
          ),
          Expanded(
            child: Text(
              '${entry.durationMs.toStringAsFixed(1)} ms',
              style: AppText.monoBody.copyWith(color: Palette.channel),
            ),
          ),
          Text(
            '+${over.toStringAsFixed(1)} ms',
            style: AppText.quiet(AppText.monoSmall),
          ),
        ],
      ),
    );
  }
}

/// Formats an elapsed millisecond count as `mm:ss.t`. The meter clock resets
/// only when the meter is recreated, so these timestamps are stable across
/// Clear taps and screen pushes.
String _formatTimestamp(int ms) {
  final totalTenths = ms ~/ 100;
  final tenths = totalTenths % 10;
  final seconds = (totalTenths ~/ 10) % 60;
  final minutes = totalTenths ~/ 600;
  final mm = minutes.toString().padLeft(2, '0');
  final ss = seconds.toString().padLeft(2, '0');
  return '$mm:$ss.$tenths';
}
