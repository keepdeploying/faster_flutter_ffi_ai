import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../app_services.dart';
import '../bridges/bridge.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';
import '../widgets/big_number.dart';
import '../widgets/screen_frame.dart';
import '../widgets/segmented.dart';

class GenerateScreen extends StatefulWidget {
  const GenerateScreen({super.key});

  @override
  State<GenerateScreen> createState() => _GenerateScreenState();
}

class _GenerateScreenState extends State<GenerateScreen> {
  final _prompt = TextEditingController(
    text: 'Explain why FFI keeps the UI smooth.',
  );
  int _generator = 0;
  bool _running = false;
  String _output = '';
  String? _error;
  int _tokens = 0;
  double? _firstTokenMs;
  double? _tokensPerSec;
  StreamSubscription<String>? _sub;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _sub?.cancel();
    _prompt.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _start(AppServices services) async {
    final gen = services.generators[_generator];
    final clock = services.nowMicros;
    setState(() {
      _running = true;
      _output = '';
      _error = null;
      _tokens = 0;
      _firstTokenMs = null;
      _tokensPerSec = null;
    });
    try {
      await gen.load();
      final start = clock();
      int? first;
      final done = Completer<void>();
      _sub = gen
          .generate(_prompt.text)
          .listen(
            (token) {
              final now = clock();
              first ??= now;
              _tokens++;
              if (!mounted) return;
              setState(() {
                _output += token;
                _firstTokenMs = (first! - start) / 1000;
                final span = now - first!;
                if (_tokens > 1 && span > 0) {
                  _tokensPerSec = (_tokens - 1) / (span / 1e6);
                }
              });
            },
            onError: (Object e) {
              if (mounted) {
                setState(
                  () => _error =
                      'Generation stopped: $e. Try the demo generator, or check that the model file is in assets/models.',
                );
              }
              if (!done.isCompleted) done.complete();
            },
            onDone: () {
              if (!done.isCompleted) done.complete();
            },
          );
      await done.future;
    } on Object catch (e) {
      if (mounted) {
        setState(
          () => _error =
              'Could not start: $e. Try the demo generator, or check that the model file is in assets/models.',
        );
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _stop(AppServices services) async {
    await services.generators[_generator].cancel();
    await _sub?.cancel();
    if (mounted) setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    final services = AppServices.of(context);
    final gens = services.generators;
    final tps = _tokensPerSec;
    final first = _firstTokenMs;
    return ScreenFrame(
      title: 'Generate text',
      stripAtBottom: true,
      children: [
        if (gens.isEmpty)
          Text('No text generator is available.', style: AppText.body)
        else ...[
          Segmented<int>(
            options: [
              for (var i = 0; i < gens.length; i++)
                SegmentOption<int>(
                  value: i,
                  label: gens[i].label,
                  icon: gens[i].isRealModel
                      ? Symbols.neurology_rounded
                      : Symbols.terminal_rounded,
                ),
            ],
            selected: _generator,
            onChanged: _running ? null : (i) => setState(() => _generator = i),
          ),
          const SizedBox(height: Space.s3),
          TextField(
            controller: _prompt,
            enabled: !_running,
            style: AppText.body,
            minLines: 1,
            maxLines: 3,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              hintText: 'Write a prompt',
              labelText: null,
            ),
          ),
          const SizedBox(height: Space.s3),
          if (_running)
            OutlinedButton.icon(
              onPressed: () => _stop(services),
              icon: const Icon(Symbols.stop_rounded, size: 28),
              label: const Text('Stop'),
            )
          else
            FilledButton.icon(
              onPressed: () => _start(services),
              icon: const Icon(Symbols.play_arrow_rounded, size: 28, fill: 1),
              label: const Text('Generate'),
            ),
          const SizedBox(height: Space.s4),
          Container(
            constraints: const BoxConstraints(minHeight: 176),
            width: double.infinity,
            padding: const EdgeInsets.all(Space.s4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Radii.medium),
              border: Border.all(color: Palette.line, width: 1.5),
            ),
            child: Semantics(
              liveRegion: true,
              label: 'Generated text',
              child: Text(
                _output.isEmpty ? 'The text appears here, token by token.' : _output,
                style: _output.isEmpty
                    ? AppText.quiet(AppText.monoBody)
                    : AppText.monoBody,
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: Space.s3),
            Text(_error!, style: AppText.small),
          ],
          const SizedBox(height: Space.s5),
          Wrap(
            spacing: Space.s6,
            runSpacing: Space.s4,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              BigNumber(
                value: tps == null ? '–' : tps.toStringAsFixed(1),
                unit: 'tokens/s',
                caption: 'speed',
                hero: true,
              ),
              BigNumber(
                value: first == null ? '–' : first.toStringAsFixed(1),
                unit: 'ms',
                caption: 'first token',
              ),
            ],
          ),
        ],
      ],
    );
  }
}
