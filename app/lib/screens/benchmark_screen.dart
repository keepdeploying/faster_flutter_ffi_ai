import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../app_services.dart';
import '../theme/bridge_style.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';
import '../widgets/big_number.dart';
import '../widgets/format.dart';
import '../widgets/screen_frame.dart';

class BenchmarkScreen extends StatefulWidget {
  const BenchmarkScreen({super.key});

  @override
  State<BenchmarkScreen> createState() => _BenchmarkScreenState();
}

class _BenchmarkScreenState extends State<BenchmarkScreen> {
  final Map<String, double> _progress = {};
  final Map<String, List<BenchRow>> _rows = {};
  StreamSubscription<BenchProgress>? _sub;
  bool _running = false;
  String? _error;
  String? _savedPath;
  bool _saving = false;

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _run(AppServices services) {
    setState(() {
      _running = true;
      _error = null;
      _savedPath = null;
      _progress.clear();
      _rows.clear();
    });
    _sub = services.benchmark.run().listen(
      (p) {
        if (!mounted) return;
        setState(() {
          _progress[p.suite] = p.fraction;
          if (p.rows.isNotEmpty) _rows[p.suite] = p.rows;
        });
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _running = false;
          _error = 'The benchmark stopped: $e. Run it again.';
        });
      },
      onDone: () {
        if (mounted) setState(() => _running = false);
      },
    );
  }

  Future<void> _stop() async {
    await _sub?.cancel();
    if (mounted) setState(() => _running = false);
  }

  Future<void> _save(AppServices services) async {
    setState(() => _saving = true);
    try {
      final path = await services.benchmark.save();
      if (mounted) setState(() => _savedPath = path);
    } on Object catch (e) {
      if (mounted) {
        setState(
          () => _error =
              'Could not save: $e. Check that the app can write to its documents folder.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final services = AppServices.of(context);
    final suites = services.benchmark.suites;
    final doneCount = suites.where((s) => (_progress[s] ?? 0) >= 1).length;
    final finished =
        !_running && suites.isNotEmpty && doneCount == suites.length;
    final hasRows = _rows.isNotEmpty;

    return ScreenFrame(
      title: 'Run the benchmark',
      children: [
        BigNumber(
          value: '$doneCount/${suites.length}',
          caption: 'suites done',
          hero: true,
        ),
        const SizedBox(height: Space.s4),
        if (_running)
          OutlinedButton.icon(
            onPressed: _stop,
            icon: const Icon(Symbols.stop_rounded, size: 28),
            label: const Text('Stop'),
          )
        else
          FilledButton.icon(
            onPressed: () => _run(services),
            icon: const Icon(Symbols.play_arrow_rounded, size: 28, fill: 1),
            label: Text(hasRows ? 'Run again' : 'Run all suites'),
          ),
        if (_error != null) ...[
          const SizedBox(height: Space.s3),
          Text(_error!, style: AppText.small),
        ],
        const SizedBox(height: Space.s5),
        if (hasRows) const _TableHeader(),
        // One list: each suite is a heading with its progress, and its result
        // rows appear under it as soon as the suite finishes.
        for (final s in suites) ...[
          _SuiteRow(name: s, fraction: _progress[s] ?? 0),
          for (final r in _rows[s] ?? const <BenchRow>[]) _ResultRow(r),
        ],
        if (hasRows) ...[
          const SizedBox(height: Space.s5),
          _SaveBar(
            canSave: finished && !services.debugBuild && !_saving,
            canShare: _savedPath != null,
            onSave: () => _save(services),
            onShare: () => services.benchmark.share(),
            savedPath: _savedPath,
            debugBuild: services.debugBuild,
            finished: finished,
          ),
        ],
      ],
    );
  }
}

/// A suite heading: its name, its state, and a hairline-thin progress bar.
/// Blue while it runs (a neutral action), ink once it is done. Green and red
/// are kept for the two bridge paths.
class _SuiteRow extends StatelessWidget {
  const _SuiteRow({required this.name, required this.fraction});

  final String name;
  final double fraction;

  @override
  Widget build(BuildContext context) {
    final done = fraction >= 1;
    final started = fraction > 0;
    final status = done
        ? 'done'
        : started
        ? '${(fraction * 100).round()}%'
        : 'waiting';
    return Semantics(
      label: '$name, $status',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(top: Space.s3, bottom: Space.s1),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    name,
                    style: done || started
                        ? AppText.heading
                        : AppText.quiet(AppText.heading),
                  ),
                ),
                if (done)
                  const Icon(Symbols.check_rounded, size: 28)
                else
                  Text(status, style: AppText.quiet(AppText.monoBody)),
              ],
            ),
            const SizedBox(height: Space.s2),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: SizedBox(
                height: 4,
                child: Stack(
                  children: [
                    const Positioned.fill(
                      child: ColoredBox(color: Palette.line),
                    ),
                    FractionallySizedBox(
                      widthFactor: fraction.clamp(0.0, 1.0),
                      child: ColoredBox(
                        color: done ? Palette.ink : Palette.accent,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TableHeader extends StatelessWidget {
  const _TableHeader();

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          'Median first, then p95 and p99.',
          style: AppText.quiet(AppText.small),
        ),
      ),
    ],
  );
}

/// One measurement: the case and its median on the first line, the tail
/// percentiles quieter underneath. The median is the number to read.
class _ResultRow extends StatelessWidget {
  const _ResultRow(this.row);

  final BenchRow row;

  @override
  Widget build(BuildContext context) {
    final color = row.kind == null
        ? Palette.quiet
        : BridgeStyle.of(row.kind!).color;
    return Semantics(
      label:
          '${row.name}: median ${formatMicros(row.p50Us)}, '
          '95th percentile ${formatMicros(row.p95Us)}, '
          '99th percentile ${formatMicros(row.p99Us)}',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: Space.s2),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Palette.line)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8, right: Space.s3),
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(row.name, style: AppText.body)),
                      Text(
                        formatMicros(row.p50Us),
                        style: AppText.monoBodyStrong,
                      ),
                    ],
                  ),
                  Text(
                    'p95 ${formatMicros(row.p95Us)}   p99 ${formatMicros(row.p99Us)}',
                    style: AppText.quiet(AppText.monoSmall),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SaveBar extends StatelessWidget {
  const _SaveBar({
    required this.canSave,
    required this.canShare,
    required this.onSave,
    required this.onShare,
    required this.savedPath,
    required this.debugBuild,
    required this.finished,
  });

  final bool canSave;
  final bool canShare;
  final VoidCallback onSave;
  final VoidCallback onShare;
  final String? savedPath;
  final bool debugBuild;
  final bool finished;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: canSave ? onSave : null,
                icon: const Icon(Symbols.save_rounded, size: 24),
                label: const Text('Save'),
              ),
            ),
            const SizedBox(width: Space.s3),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: canShare ? onShare : null,
                icon: const Icon(Symbols.ios_share_rounded, size: 24),
                label: const Text('Share'),
              ),
            ),
          ],
        ),
        const SizedBox(height: Space.s3),
        if (savedPath != null)
          Text('Saved to $savedPath', style: AppText.quiet(AppText.monoSmall))
        else if (debugBuild)
          Text(
            'Saving is off in a debug build. Run with --profile.',
            style: AppText.quiet(AppText.small),
          )
        else if (!finished)
          Text(
            'Save becomes available when every suite is done.',
            style: AppText.quiet(AppText.small),
          ),
      ],
    );
  }
}
