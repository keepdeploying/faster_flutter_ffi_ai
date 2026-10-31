// The Generate screen is the text-streaming demo. It mirrors Classify's shape:
// a Model toggle (SmolLM vs Qwen) and a Bridge toggle (FFI vs Channel). The
// four combinations are built on demand by `services.generatorAt`; the C
// canned-text demo generator is retained in the package but no longer wired in.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../app_services.dart';
import '../bridges/bridge.dart';
import '../bridges/generator_adapters.dart'
    show defaultGeneratorAt, llmModelCandidates;
import '../theme/theme.dart';
import '../theme/tokens.dart';
import '../widgets/big_number.dart';
import '../widgets/screen_frame.dart';
import '../widgets/segmented.dart';
import 'model_screen.dart';

class GenerateScreen extends StatefulWidget {
  const GenerateScreen({super.key});

  @override
  State<GenerateScreen> createState() => _GenerateScreenState();
}

class _GenerateScreenState extends State<GenerateScreen> {
  final _prompt = TextEditingController(
    text: 'Explain why FFI keeps the UI smooth.',
  );
  final _scroll = ScrollController();

  GenerateModel _model = GenerateModel.smol;
  GenerateBridge _bridge = GenerateBridge.ffi;

  TokenGenerator? _current;
  (GenerateModel, GenerateBridge)? _currentKey;

  bool _running = false;
  bool _qwenPresent = false;
  bool _qwenChecked = false;

  String _output = '';
  String? _error;
  int _tokens = 0;
  double? _firstTokenMs;
  double? _tokensPerSec;
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    _checkQwenPresent();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _current?.dispose();
    _prompt.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _checkQwenPresent() async {
    final candidates = await llmModelCandidates();
    final present = candidates.any((File f) => f.existsSync());
    if (!mounted) return;
    setState(() {
      _qwenPresent = present;
      _qwenChecked = true;
      // If Qwen was selected but is not present, fall back to SmolLM so the
      // Generate button is not disabled.
      if (_model == GenerateModel.qwen && !present) {
        _model = GenerateModel.smol;
      }
    });
  }

  /// Builds (and caches) the generator for the current (model, bridge).
  TokenGenerator _generatorFor(AppServices services) {
    final key = (_model, _bridge);
    if (_currentKey == key && _current != null) return _current!;
    final factory = services.generatorAt ?? defaultGeneratorAt;
    _current?.dispose();
    _current = factory(_model, _bridge);
    _currentKey = key;
    return _current!;
  }

  bool get _qwenDisabled => _qwenChecked && !_qwenPresent;

  Future<void> _start(AppServices services) async {
    final gen = _generatorFor(services);
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
      _sub = gen.generate(_prompt.text).listen(
        (token) {
          final now = clock();
          first ??= now;
          _tokens++;
          if (!mounted) return;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scroll.hasClients) {
              _scroll.jumpTo(_scroll.position.maxScrollExtent);
            }
          });
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
            setState(() => _error = 'Generation stopped. $e');
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
        setState(() => _error = 'Could not start. $e');
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _stop() async {
    await _current?.cancel();
    await _sub?.cancel();
    if (mounted) setState(() => _running = false);
  }

  bool _isReal() {
    final c = _current;
    return c != null && c.isRealModel;
  }

  @override
  Widget build(BuildContext context) {
    final services = AppServices.of(context);
    final tps = _tokensPerSec;
    final first = _firstTokenMs;
    return ScreenFrame(
      title: 'Generate text',
      stripAtBottom: true,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: Space.s4),
          child: Text(
            'Tokens arrive one at a time. The strip under the stream shows '
            'the UI keeps its frames while the model thinks.',
            style: AppText.quiet(AppText.body),
          ),
        ),
        // Model toggle. Mirrors the shape of Classify's bridge toggle.
        Segmented<GenerateModel>(
          options: [
            SegmentOption<GenerateModel>(
              value: GenerateModel.smol,
              label: 'SmolLM2 135M',
              icon: Symbols.toys_rounded,
            ),
            SegmentOption<GenerateModel>(
              value: GenerateModel.qwen,
              label: _qwenDisabled
                  ? 'Qwen2.5 0.5B (missing)'
                  : 'Qwen2.5 0.5B',
              icon: Symbols.neurology_rounded,
              enabled: !_qwenDisabled,
            ),
          ],
          selected: _model,
          onChanged: _running
              ? null
              : (m) => setState(() {
                  _model = m;
                }),
        ),
        const SizedBox(height: Space.s3),
        // Bridge toggle. Channel on the left, FFI on the right, in the same
        // order the slides read them: the thing we are replacing comes first.
        Segmented<GenerateBridge>(
          options: const [
            SegmentOption<GenerateBridge>(
              value: GenerateBridge.channel,
              label: 'Channel',
              icon: Symbols.cell_tower_rounded,
              color: Palette.channel,
              tint: Palette.channelTint,
            ),
            SegmentOption<GenerateBridge>(
              value: GenerateBridge.ffi,
              label: 'FFI',
              icon: Symbols.bolt_rounded,
              color: Palette.ffi,
              tint: Palette.ffiTint,
            ),
          ],
          selected: _bridge,
          onChanged: _running
              ? null
              : (b) => setState(() {
                  _bridge = b;
                }),
        ),
        const SizedBox(height: Space.s2),
        Text(
          _qwenDisabled
              ? 'The full Qwen model is not on this device yet. Open the LLM '
                    'model page to get it, or run the demo on SmolLM in the '
                    'meantime.'
              : 'Same model on both sides; only the bridge changes between '
                'Dart FFI and a platform channel. SmolLM2 is bundled with '
                'the app; Qwen is the fuller model.',
          style: AppText.quiet(AppText.small),
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
          FilledButton.icon(
            onPressed: _stop,
            icon: const Icon(Symbols.stop_rounded, size: 28, fill: 1),
            label: const Text('Stop'),
            style: FilledButton.styleFrom(
              backgroundColor: Palette.channel,
              foregroundColor: const Color(0xFF20344B),
            ),
          )
        else
          FilledButton.icon(
            onPressed: () => _start(services),
            icon: const Icon(Symbols.play_arrow_rounded, size: 28, fill: 1),
            label: const Text('Generate'),
          ),
        const SizedBox(height: Space.s4),
        // A fixed height, so the screen does not jump while text streams in.
        // It follows the newest words. While generating, a secondary Stop pill
        // overlays the top-right corner so the control is reachable whichever
        // scroll position the user is at within the output area.
        Stack(
          children: [
            Container(
              height: 192,
              width: double.infinity,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Radii.medium),
                border: Border.all(color: Palette.line, width: 1.5),
              ),
              clipBehavior: Clip.antiAlias,
              child: SingleChildScrollView(
                controller: _scroll,
                padding: const EdgeInsets.symmetric(
                  horizontal: Space.s4,
                  vertical: Space.s3,
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: Semantics(
                    liveRegion: true,
                    label: 'Generated text',
                    child: Text(
                      _output.isEmpty
                          ? 'The text appears here, token by token.'
                          : _output,
                      style: _output.isEmpty
                          ? AppText.quiet(AppText.monoBody)
                          : AppText.monoBody,
                    ),
                  ),
                ),
              ),
            ),
            if (_running)
              Positioned(
                top: Space.s2,
                right: Space.s2,
                child: Material(
                  color: Palette.channel,
                  shape: const StadiumBorder(),
                  elevation: 0,
                  child: InkWell(
                    customBorder: const StadiumBorder(),
                    onTap: _stop,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Space.s3,
                        vertical: Space.s2,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Symbols.stop_rounded,
                            size: 18,
                            fill: 1,
                            color: Color(0xFF20344B),
                          ),
                          const SizedBox(width: Space.s1),
                          Text(
                            'Stop',
                            style: AppText.smallStrong.copyWith(
                              color: const Color(0xFF20344B),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: Space.s3),
          Text(_error!, style: AppText.small),
          if (_isReal() && _model == GenerateModel.qwen) ...[
            const SizedBox(height: Space.s2),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const ModelScreen(),
                ),
              ),
              icon: const Icon(Symbols.cloud_download_rounded, size: 20),
              label: const Text('Open the LLM model page'),
            ),
          ],
        ],
        const SizedBox(height: Space.s5),
        BigNumber(
          value: tps == null ? '–' : tps.toStringAsFixed(1),
          unit: 'tokens/s',
          caption: 'generation speed',
          hero: true,
        ),
        const SizedBox(height: Space.s3),
        Semantics(
          label:
              'First token ${first == null ? 'not yet' : '${first.toStringAsFixed(1)} milliseconds'}',
          excludeSemantics: true,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                first == null ? '–' : first.toStringAsFixed(1),
                style: AppText.monoHeading,
              ),
              const SizedBox(width: Space.s1),
              Text('ms', style: AppText.quiet(AppText.monoBody)),
              const SizedBox(width: Space.s3),
              Text('to the first token', style: AppText.quiet(AppText.body)),
            ],
          ),
        ),
      ],
    );
  }
}
