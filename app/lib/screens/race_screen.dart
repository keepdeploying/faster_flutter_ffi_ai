import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../app_services.dart';
import '../bridges/bridge.dart';
import '../theme/bridge_style.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';
import '../widgets/big_number.dart';
import '../widgets/format.dart';
import '../widgets/log_bar_chart.dart';
import '../widgets/screen_frame.dart';

/// The five payload sizes of the round-trip suite, and what each one stands for.
const raceSizes = <int, String>{
  0: 'An empty call: the fixed cost of crossing.',
  1024: 'A small message.',
  65536: 'A thumbnail.',
  602112: 'A 224 × 224 float32 tensor, the model input.',
  8294400: 'A 1920 × 1080 RGBA frame.',
};

class RaceScreen extends StatefulWidget {
  const RaceScreen({super.key, this.initialBytes = 65536});

  final int initialBytes;

  @override
  State<RaceScreen> createState() => _RaceScreenState();
}

class _RaceScreenState extends State<RaceScreen> {
  late int _bytes = widget.initialBytes;
  bool _running = false;
  bool _stop = false;
  String? _error;
  final Map<BridgeKind, double> _p50 = {};
  final Set<BridgeKind> _selected = {...BridgeKind.values};

  // Fewer samples for big payloads, so the race ends in a few seconds.
  static int _runsFor(int bytes) => bytes >= 8000000
      ? 40
      : bytes >= 600000
      ? 120
      : 400;

  static const _batch = 10;
  static const _warmup = 10;

  Future<void> _run(AppServices services) async {
    setState(() {
      _running = true;
      _stop = false;
      _error = null;
      _p50.clear();
    });
    final bytes = _bytes;
    final payload = Uint8List(bytes);
    for (var i = 0; i < bytes; i++) {
      payload[i] = (i * 31) & 0xFF;
    }
    final expected = checksum(payload);
    final bridges = [
      for (final b in services.payloadBridges)
        if (_selected.contains(b.kind)) b,
    ];
    final samples = {for (final b in bridges) b.kind: <double>[]};
    final clock = services.nowMicros;
    final runs = _runsFor(bytes);
    try {
      for (final b in bridges) {
        await b.warmUp(bytes);
        for (var i = 0; i < _warmup; i++) {
          await b.roundTrip(payload);
        }
      }
      // Round-robin in small batches, so every bar grows at the same time.
      for (var done = 0; done < runs && !_stop && mounted; done += _batch) {
        for (final b in bridges) {
          final list = samples[b.kind]!;
          for (var i = 0; i < _batch; i++) {
            final t0 = clock();
            final sum = await b.roundTrip(payload);
            final t1 = clock();
            if (sum != expected) {
              throw StateError(
                '${BridgeStyle.of(b.kind).longLabel} returned the wrong checksum.',
              );
            }
            list.add((t1 - t0).toDouble());
          }
        }
        if (!mounted) return;
        setState(() {
          for (final e in samples.entries) {
            _p50[e.key] = _median(e.value);
          }
        });
        // Let the frames draw between batches.
        await Future<void>.delayed(Duration.zero);
      }
    } on Object catch (e) {
      if (mounted) {
        setState(
          () => _error =
              'The race stopped: $e. Run it again, or pick a smaller payload.',
        );
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  static double _median(List<double> v) {
    final s = [...v]..sort();
    final n = s.length;
    return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
  }

  @override
  Widget build(BuildContext context) {
    final services = AppServices.of(context);
    final kinds = [for (final b in services.payloadBridges) b.kind];
    final measured = kinds.where(_p50.containsKey).toList();
    String heroValue = '–';
    String? caption;
    if (measured.length >= 2) {
      measured.sort((a, b) => _p50[a]!.compareTo(_p50[b]!));
      final fast = measured.first;
      final slow = measured.last;
      final ratio = _p50[slow]! / _p50[fast]!;
      heroValue = ratio >= 100
          ? ratio.toStringAsFixed(0)
          : ratio.toStringAsFixed(1);
      caption =
          '${BridgeStyle.of(fast).label} is faster than ${BridgeStyle.of(slow).label}';
      heroValue = '$heroValue×';
    }

    return ScreenFrame(
      title: 'Race the bridges',
      children: [
        Row(
          children: [
            for (final size in raceSizes.keys) ...[
              if (size != raceSizes.keys.first) const SizedBox(width: Space.s2),
              Expanded(
                child: _SizeChip(
                  bytes: size,
                  selected: size == _bytes,
                  onTap: _running ? null : () => setState(() => _bytes = size),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: Space.s3),
        Text(
          '${groupDigits(_bytes)} bytes. ${raceSizes[_bytes] ?? ''}',
          style: AppText.quiet(AppText.small),
        ),
        const SizedBox(height: Space.s3),
        Wrap(
          spacing: Space.s2,
          runSpacing: Space.s2,
          children: [
            for (final k in kinds)
              _BridgeChip(
                kind: k,
                selected: _selected.contains(k),
                onTap: _running
                    ? null
                    : () => setState(() {
                        if (!_selected.add(k)) _selected.remove(k);
                      }),
              ),
          ],
        ),
        const SizedBox(height: Space.s3),
        Row(
          children: [
            Expanded(child: BigNumber(value: heroValue, hero: true)),
            const SizedBox(width: Space.s3),
            if (_running)
              OutlinedButton.icon(
                onPressed: () => setState(() => _stop = true),
                icon: const Icon(Symbols.stop_rounded, size: 28),
                label: const Text('Stop'),
              )
            else
              FilledButton.icon(
                onPressed: _selected.isEmpty ? null : () => _run(services),
                icon: const Icon(Symbols.play_arrow_rounded, size: 28, fill: 1),
                label: const Text('Run'),
              ),
          ],
        ),
        if (_selected.isEmpty)
          Text(
            'Pick at least one bridge.',
            style: AppText.quiet(AppText.body),
          )
        else if (caption != null)
          Text(caption, style: AppText.quiet(AppText.body))
        else
          Text('Pick a payload, then run.', style: AppText.quiet(AppText.body)),
        if (_error != null) ...[
          const SizedBox(height: Space.s3),
          Text(_error!, style: AppText.small.copyWith(color: Palette.channel)),
        ],
        const SizedBox(height: Space.s5),
        LogBarChart(
          bars: [
            for (final k in kinds)
              LogBar(
                label: BridgeStyle.of(k).longLabel,
                icon: BridgeStyle.of(k).icon,
                color: BridgeStyle.of(k).color,
                valueUs: _p50[k],
              ),
          ],
        ),
        const SizedBox(height: Space.s2),
        Text(
          'Median round trip. Lower is faster. Each gridline is ten times the one before.',
          style: AppText.quiet(AppText.small),
        ),
      ],
    );
  }
}

/// One payload size: the number big, the unit small beneath it, so five fit in
/// a row on a phone.
class _SizeChip extends StatelessWidget {
  const _SizeChip({
    required this.bytes,
    required this.selected,
    required this.onTap,
  });

  final int bytes;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final label = formatBytes(bytes);
    final i = label.indexOf(' ');
    final number = label.substring(0, i);
    final unit = label.substring(i + 1);
    final enabled = onTap != null || selected;
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: 'Payload $label',
      excludeSemantics: true,
      child: Material(
        color: selected ? Palette.accentTint : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.medium),
          side: BorderSide(
            color: selected ? Palette.accent : Palette.line,
            width: selected ? 2 : 1.5,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.medium),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 64),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    number,
                    style:
                        (selected ? AppText.monoBodyStrong : AppText.monoBody)
                            .copyWith(
                              color: enabled ? Palette.ink : Palette.quiet,
                            ),
                  ),
                  Text(
                    unit,
                    style: AppText.monoSmall.copyWith(
                      color: enabled ? Palette.quietText : Palette.quiet,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A compact bridge toggle: when selected the chip wears the bridge's colour as
/// an outline and tint; when not, it stays plain. Disabled while a race runs.
class _BridgeChip extends StatelessWidget {
  const _BridgeChip({
    required this.kind,
    required this.selected,
    required this.onTap,
  });

  final BridgeKind kind;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final style = BridgeStyle.of(kind);
    final enabled = onTap != null;
    final borderColor = selected ? style.color : Palette.line;
    final fillColor = selected ? style.tint : Colors.transparent;
    final iconColor = selected
        ? style.color
        : (enabled ? Palette.quietText : Palette.quiet);
    final textColor = enabled ? Palette.ink : Palette.quiet;
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: style.longLabel,
      excludeSemantics: true,
      child: Material(
        color: fillColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.medium),
          side: BorderSide(
            color: borderColor,
            width: selected ? 2 : 1.5,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.medium),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Space.s3,
              vertical: Space.s2,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(style.icon, size: 18, color: iconColor),
                const SizedBox(width: Space.s2),
                Text(
                  style.label,
                  style: AppText.small.copyWith(
                    color: textColor,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
