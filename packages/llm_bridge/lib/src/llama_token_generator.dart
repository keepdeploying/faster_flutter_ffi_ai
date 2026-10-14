import 'dart:async';

import 'backend.dart';
import 'chat.dart';
import 'ffi_backend.dart';
import 'generation_stats.dart';

/// Streams text from a GGUF model running in llama.cpp, over dart:ffi.
///
/// The decode loop runs on a native thread. Each token comes back to Dart
/// through a `NativeCallable.listener`, so the UI isolate never waits for the
/// model. The shape matches the app's `TokenGenerator` interface (`label`,
/// `isRealModel`, `generate`, `cancel`, `dispose`), but this package does not
/// import the app: wrap it in a few lines.
///
/// ```dart
/// final llm = LlamaTokenGenerator();
/// await llm.load(modelPath: '/data/.../qwen2.5-0.5b-instruct-q4_k_m.gguf');
/// await for (final piece in llm.generate('Name three colours.')) {
///   stdout.write(piece);
/// }
/// print(llm.lastStats);
/// llm.dispose();
/// ```
class LlamaTokenGenerator {
  /// [backend] is only for tests; the default talks to the native library.
  LlamaTokenGenerator({
    LlamaBackend? backend,
    this.label = 'llama.cpp',
    this.onStats,
  }) : _backend = backend ?? FfiLlamaBackend();

  final LlamaBackend _backend;

  /// Name shown in the UI.
  final String label;

  /// Called with the timings of every finished generation.
  final void Function(GenerationStats stats)? onStats;

  /// Always true: this is a real model, not the C demo generator.
  bool get isRealModel => true;

  int? _model;
  _Run? _tail; // the newest generation; earlier ones were cancelled by it
  bool _disposed = false;
  List<ChatMessage> _prefix = const [];
  double _temperature = 0;
  int _seed = 0;
  GenerationStats? _lastStats;

  bool get isLoaded => _model != null;

  /// Timings of the most recent generation that finished or was cancelled.
  GenerationStats? get lastStats => _lastStats;

  /// Loads the GGUF at [modelPath]. Takes a moment; the work happens off the
  /// calling isolate.
  ///
  /// [contextSize] is the window in tokens for prompt plus answer; the KV cache
  /// grows with it. [threads] is the number of CPU threads for decoding: use
  /// the number of fast cores, 4 is right for most phones. [systemPrompt] opens
  /// every conversation. [temperature] 0 means greedy decoding, so the same
  /// prompt gives the same answer (what a benchmark wants).
  Future<void> load({
    required String modelPath,
    int contextSize = 1024,
    int threads = 4,
    String? systemPrompt = 'You are a helpful assistant.',
    double temperature = 0,
    int seed = 0,
  }) async {
    _checkNotDisposed();
    if (contextSize < 16) {
      throw ArgumentError.value(
        contextSize,
        'contextSize',
        'must be at least 16',
      );
    }
    if (threads < 1) {
      throw ArgumentError.value(threads, 'threads', 'must be at least 1');
    }
    await _unload();
    final model = await _backend.loadModel(
      path: modelPath,
      contextSize: contextSize,
      threads: threads,
    );
    if (_disposed) {
      // disposed while the model was loading
      _backend.unloadModel(model);
      return;
    }
    _model = model;
    _prefix = [if (systemPrompt != null) ChatMessage.system(systemPrompt)];
    _temperature = temperature;
    _seed = seed;
  }

  /// Streams the model's answer to [prompt] piece by piece.
  ///
  /// The prompt is wrapped in the model's chat template (system message from
  /// [load], then [prompt] as the user message). The generation starts when the
  /// stream is listened to. Cancelling the subscription, or calling [cancel],
  /// stops the native thread. Starting a new generation first cancels the one
  /// that is running. Errors from the native side arrive as stream errors.
  Stream<String> generate(String prompt, {int maxTokens = 128}) {
    _checkNotDisposed();
    if (maxTokens < 1) {
      throw ArgumentError.value(maxTokens, 'maxTokens', 'must be at least 1');
    }
    late final StreamController<String> controller;
    _Run? run;
    controller = StreamController<String>(
      onListen: () {
        run = _Run(this, controller, prompt, maxTokens);
        unawaited(run!.start());
      },
      // Awaiting the future makes `await subscription.cancel()` return only
      // once the native thread has stopped.
      onCancel: () => run?.cancelAndWait(),
    );
    return controller.stream;
  }

  /// Stops the running generation, if any, and waits until the native thread
  /// has finished. The stream returned by [generate] then closes normally.
  Future<void> cancel() async {
    final run = _tail;
    if (run == null) return;
    await run.cancelAndWait();
  }

  /// Unloads the model and releases the native callback. Safe to call twice.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final run = _tail;
    run?.cancel();
    final model = _model;
    _model = null;
    if (model != null) _backend.unloadModel(model); // joins the worker
    _backend.dispose();
    // The worker is gone and no more events will arrive: close the stream.
    run?.abandon();
  }

  Future<void> _unload() async {
    await cancel();
    final model = _model;
    _model = null;
    if (model != null) _backend.unloadModel(model);
  }

  void _checkNotDisposed() {
    if (_disposed) throw StateError('LlamaTokenGenerator is disposed');
  }
}

/// One call of `generate`: owns the native stream id and the timing.
class _Run {
  _Run(this._owner, this._controller, this._prompt, this._maxTokens);

  final LlamaTokenGenerator _owner;
  final StreamController<String> _controller;
  final String _prompt;
  final int _maxTokens;

  final Stopwatch _clock = Stopwatch();
  final Completer<void> _finished = Completer<void>();
  int? _model;
  int? _streamId;
  bool _cancelRequested = false;
  Duration? _firstToken;
  Duration? _lastToken;
  int _tokensSeen = 0;

  Future<void> get finished => _finished.future;

  Future<void> start() async {
    _clock.start();
    final owner = _owner;
    final previous = owner._tail;
    owner._tail = this;
    try {
      // One generation at a time: the previous one is cancelled and awaited.
      // Each run waits only for its direct predecessor, which in turn waited
      // for its own, so several queued calls run strictly one after another.
      if (previous != null) {
        previous.cancel();
        await previous.finished;
      }

      final model = owner._model;
      if (model == null) throw StateError('call load() before generate()');
      if (_cancelRequested) return _close();
      _model = model;

      final messages = [...owner._prefix, ChatMessage.user(_prompt)];
      final formatted =
          owner._backend.formatChat(model, messages, addAssistant: true) ??
          formatChatMl(messages);

      _streamId = owner._backend.startGeneration(
        model,
        prompt: formatted,
        maxTokens: _maxTokens,
        temperature: owner._temperature,
        seed: owner._seed,
        onEvent: _onEvent,
      );
      // cancel() may have been called while the native thread was starting.
      if (_cancelRequested) owner._backend.cancel(model, _streamId!);
    } on Object catch (error, stack) {
      _fail(error, stack);
    }
  }

  Future<void> cancelAndWait() {
    cancel();
    return finished;
  }

  /// Ends the run without waiting for a DONE event that will never come.
  void abandon() => _close();

  void cancel() {
    if (_cancelRequested) return;
    _cancelRequested = true;
    final model = _model, id = _streamId;
    if (model != null && id != null && !_finished.isCompleted) {
      _owner._backend.cancel(model, id);
    }
  }

  void _onEvent(LlamaEvent event) {
    switch (event) {
      case LlamaTokenEvent(:final text):
        final now = _clock.elapsed;
        _firstToken ??= now;
        _lastToken = now;
        _tokensSeen++;
        if (!_controller.isClosed && !_cancelRequested) _controller.add(text);
      case LlamaDoneEvent(:final stats):
        _record(stats);
        _close();
      case LlamaErrorEvent(:final message):
        _fail(StateError(message), StackTrace.current);
    }
  }

  void _record(NativeStats native) {
    final first = _firstToken, last = _lastToken;
    final decode = first != null && last != null ? last - first : Duration.zero;
    final stats = GenerationStats(
      promptTokens: native.promptTokens,
      generatedTokens: native.generatedTokens,
      stopReason: native.stopReason,
      timeToFirstToken: first ?? _clock.elapsed,
      tokensPerSecond: _tokensSeen > 1 && decode.inMicroseconds > 0
          ? (_tokensSeen - 1) * 1e6 / decode.inMicroseconds
          : 0,
      total: _clock.elapsed,
      native: native,
    );
    _owner._lastStats = stats;
    _owner.onStats?.call(stats);
  }

  void _fail(Object error, StackTrace stack) {
    if (!_controller.isClosed) _controller.addError(error, stack);
    _close();
  }

  void _close() {
    if (!_finished.isCompleted) _finished.complete();
    if (identical(_owner._tail, this)) _owner._tail = null;
    if (!_controller.isClosed) unawaited(_controller.close());
  }
}
