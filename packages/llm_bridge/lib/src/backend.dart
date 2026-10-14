import 'chat.dart';
import 'generation_stats.dart';

/// One event of a running generation, in the order the worker produced them.
sealed class LlamaEvent {
  const LlamaEvent();
}

/// A piece of text (usually one token).
final class LlamaTokenEvent extends LlamaEvent {
  const LlamaTokenEvent(this.text);
  final String text;
}

/// The generation finished normally, or was cancelled.
final class LlamaDoneEvent extends LlamaEvent {
  const LlamaDoneEvent(this.stats);
  final NativeStats stats;
}

/// The generation failed.
final class LlamaErrorEvent extends LlamaEvent {
  const LlamaErrorEvent(this.message);
  final String message;
}

/// The native layer, as plain Dart. [FfiLlamaBackend] is the real one; tests
/// use a fake, so the stream and cancel logic runs without a model.
abstract interface class LlamaBackend {
  /// Loads a model and returns a handle. Throws [StateError] with a readable
  /// message on failure. Must not block the calling isolate for long.
  Future<int> loadModel({
    required String path,
    required int contextSize,
    required int threads,
  });

  /// Formats [messages] with the model's own chat template, or returns null if
  /// llama.cpp does not know that template.
  String? formatChat(
    int model,
    List<ChatMessage> messages, {
    required bool addAssistant,
  });

  /// Starts a generation and returns its stream id at once. [onEvent] gets the
  /// events in order, ending with [LlamaDoneEvent] or [LlamaErrorEvent].
  /// Throws [StateError] when a generation is already running.
  int startGeneration(
    int model, {
    required String prompt,
    required int maxTokens,
    required double temperature,
    required int seed,
    required void Function(LlamaEvent event) onEvent,
  });

  /// Asks a running generation to stop. Returns at once.
  void cancel(int model, int streamId);

  /// Stops any generation, then frees the model.
  void unloadModel(int model);

  /// Releases the backend itself (the callback, for the real one).
  void dispose();
}
