import 'dart:async';

import 'package:llm_bridge/llm_bridge.dart';

/// A scripted stand-in for the native layer. Emits [pieces] one by one, every
/// [delay], and honours cancel like the real worker thread does: it stops after
/// the current piece and posts a DONE event with StopReason.cancelled.
class FakeBackend implements LlamaBackend {
  FakeBackend({
    this.pieces = const ['Hello', ',', ' world', '!'],
    this.delay = const Duration(milliseconds: 5),
    this.template = _qwenLike,
    this.failLoad = false,
  });

  List<String> pieces;
  Duration delay;

  /// What formatChat returns; null simulates "llama.cpp does not know the
  /// template".
  String? Function(List<ChatMessage> messages)? formatter;
  String? template;
  bool failLoad;

  static const _qwenLike = 'chatml';

  // Observations for the tests.
  final List<String> loadedPaths = [];
  final List<int> unloaded = [];
  final List<String> prompts = [];
  final List<int> cancelled = [];
  final List<int> maxTokensSeen = [];
  final List<double> temperaturesSeen = [];
  int disposeCalls = 0;
  String? errorToEmit;

  int _nextModel = 100;
  int _nextStream = 1;
  final Set<int> _cancelRequested = {};
  bool _running = false;

  @override
  Future<int> loadModel({
    required String path,
    required int contextSize,
    required int threads,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 1));
    if (failLoad) throw StateError('cannot load model from $path');
    loadedPaths.add(path);
    return _nextModel++;
  }

  @override
  String? formatChat(
    int model,
    List<ChatMessage> messages, {
    required bool addAssistant,
  }) {
    if (formatter != null) return formatter!(messages);
    if (template == null) return null;
    // A recognisable, fake template: "[role] content" lines.
    return '${messages.map((m) => '[${m.role}] ${m.content}').join('\n')}\n[assistant] ';
  }

  @override
  int startGeneration(
    int model, {
    required String prompt,
    required int maxTokens,
    required double temperature,
    required int seed,
    required void Function(LlamaEvent event) onEvent,
  }) {
    if (_running) throw StateError('a generation is already running');
    _running = true;
    prompts.add(prompt);
    maxTokensSeen.add(maxTokens);
    temperaturesSeen.add(temperature);
    final id = _nextStream++;
    unawaited(_run(id, maxTokens, onEvent));
    return id;
  }

  Future<void> _run(
    int id,
    int maxTokens,
    void Function(LlamaEvent) onEvent,
  ) async {
    var sent = 0;
    var stop = StopReason.endOfText;
    if (errorToEmit != null) {
      _running = false;
      await Future<void>.delayed(delay);
      onEvent(LlamaErrorEvent(errorToEmit!));
      return;
    }
    for (final piece in pieces) {
      await Future<void>.delayed(delay);
      if (_cancelRequested.contains(id)) {
        stop = StopReason.cancelled;
        break;
      }
      if (sent >= maxTokens) {
        stop = StopReason.maxTokens;
        break;
      }
      onEvent(LlamaTokenEvent(piece));
      sent++;
    }
    _running = false;
    onEvent(
      LlamaDoneEvent(
        NativeStats(
          promptTokens: 12,
          generatedTokens: sent,
          stopReason: stop,
          promptEval: const Duration(milliseconds: 3),
          firstToken: const Duration(milliseconds: 4),
          decode: delay * (sent > 1 ? sent - 1 : 0),
          total: delay * sent,
        ),
      ),
    );
  }

  @override
  void cancel(int model, int streamId) {
    cancelled.add(streamId);
    _cancelRequested.add(streamId);
  }

  @override
  void unloadModel(int model) => unloaded.add(model);

  @override
  void dispose() => disposeCalls++;
}
