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
    final bridges = services.payloadBridges;
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
          () => _error = 'The race stopped: $e. Run it again, or pick a smaller payload.',
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
      heroValue = ratio >= 100 ? ratio.toStringAsFixed(0) : ratio.toStringAsFixed(1);
      caption =
          '${BridgeStyle.of(fast).label} is faster than ${BridgeStyle.of(slow).label}';
      heroValue = '$heroValue×';
    }

    return ScreenFrame(
      title: 'Race the bridges',
      children: [
        Wrap(
          spacing: Space.s2,
          runSpacing: Space.s2,
          children: [
            for (final size in raceSizes.keys)
              _SizeChip(
                bytes: size,
                selected: size == _bytes,
                onTap: _running ? null : () => setState(() => _bytes = size),
              ),
          ],
        ),
        const SizedBox(height: Space.s3),
        Text(
          '${groupDigits(_bytes)} bytes. ${raceSizes[_bytes] ?? ''}',
          style: AppText.quiet(AppText.small),
        ),
        const SizedBox(height: Space.s4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: BigNumber(value: heroValue, caption: caption, hero: true),
            ),
          ],
        ),
        const SizedBox(height: Space.s4),
        if (_running)
          OutlinedButton.icon(
            onPressed: () => setState(() => _stop = true),
            icon: const Icon(Symbols.stop_rounded, size: 28),
            label: const Text('Stop'),
          )
        else
          FilledButton.icon(
            onPressed: () => _run(services),
            icon: const Icon(Symbols.play_arrow_rounded, size: 28, fill: 1),
            label: Text(_p50.isEmpty ? 'Run the race' : 'Run again'),
          ),
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
    return Semantics(
      button: true,
      selected: selected,
      enabled: onTap != null || selected,
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
          child: Container(
            constraints: const BoxConstraints(minWidth: 64, minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: Space.s4),
            alignment: Alignment.center,
            child: Text(
              label,
              style: selected
                  ? AppText.monoBodyStrong
                  : AppText.monoBody.copyWith(
                      color: onTap == null ? Palette.quiet : Palette.ink,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
