import 'dart:async';

import 'package:flutter/services.dart';

/// Streams text from a GGUF model running in llama.cpp, over an EventChannel.
///
/// The decode loop runs natively (Kotlin on Android, Swift on iOS) against the
/// same `libllm_bridge` library the FFI path uses. Tokens arrive one at a time
/// as the native side pulls them with `llb_pull_next_token` and emits them
/// through the `faster_flutter/llm` EventChannel.
///
/// The shape mirrors [`LlamaTokenGenerator`] from `package:llm_bridge`
/// (`load`, `generate`, `cancel`, `dispose`) so the two can swap behind the
/// same adapter in the app. [systemPrompt] is accepted for API symmetry but
/// is not applied in this version: the native side uses the user prompt
/// directly, which keeps the comparison with FFI focused on the bridge rather
/// than template differences.
class ChannelLlamaGenerator {
  ChannelLlamaGenerator();

  static const EventChannel _channel = EventChannel('faster_flutter/llm');

  bool _loaded = false;
  String? _modelPath;
  int _contextSize = 1024;
  int _threads = 4;
  double _temperature = 0;
  int _seed = 0;
  StreamSubscription<dynamic>? _sub;

  /// True after [load] has stored the model configuration.
  bool get isLoaded => _loaded;

  /// Records the model configuration. Actual loading happens lazily on the
  /// native side the first time [generate] runs with a new [modelPath].
  ///
  /// [systemPrompt] is accepted for API symmetry with the FFI generator but
  /// is not applied: the channel path sends the user prompt as-is.
  Future<void> load({
    required String modelPath,
    int contextSize = 1024,
    int threads = 4,
    String? systemPrompt,
    double temperature = 0.0,
    int seed = 0,
  }) async {
    _modelPath = modelPath;
    _contextSize = contextSize;
    _threads = threads;
    _temperature = temperature;
    _seed = seed;
    _loaded = true;
  }

  /// Streams the model's answer to [prompt] piece by piece. Each event on the
  /// returned stream is one UTF-8 token (or a few, see `llm_bridge.cpp`).
  /// Cancelling the subscription asks the native side to stop and close.
  Stream<String> generate(String prompt, {int maxTokens = 128}) {
    if (!_loaded) {
      throw StateError('ChannelLlamaGenerator.load() has not completed');
    }
    final controller = StreamController<String>();
    _sub = _channel
        .receiveBroadcastStream(<String, Object?>{
          'modelPath': _modelPath,
          'prompt': prompt,
          'contextSize': _contextSize,
          'threads': _threads,
          'maxTokens': maxTokens,
          'temperature': _temperature,
          'seed': _seed,
        })
        .listen(
          (dynamic token) => controller.add(token as String),
          onError: controller.addError,
          onDone: controller.close,
        );
    controller.onCancel = () => _sub?.cancel();
    return controller.stream;
  }

  /// Stops the running generation, if any. The stream returned by [generate]
  /// then closes normally.
  Future<void> cancel() async {
    await _sub?.cancel();
    _sub = null;
  }

  /// Drops the subscription and marks the generator unloaded. Safe to call
  /// twice. The native model stays cached until a different [modelPath] is
  /// requested or the engine detaches.
  void dispose() {
    _sub?.cancel();
    _sub = null;
    _loaded = false;
  }
}
