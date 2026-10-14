/// Why a generation ended.
enum StopReason {
  /// The model produced an end-of-generation token.
  endOfText,

  /// `maxTokens` was reached.
  maxTokens,

  /// The caller cancelled.
  cancelled,

  /// The context window is full.
  contextFull;

  static StopReason fromNative(int code) => switch (code) {
    0 => endOfText,
    1 => maxTokens,
    2 => cancelled,
    _ => contextFull,
  };
}

/// What the native side measured for one generation (monotonic clock, on the
/// worker thread, before anything crosses the bridge).
class NativeStats {
  const NativeStats({
    required this.promptTokens,
    required this.generatedTokens,
    required this.stopReason,
    required this.promptEval,
    required this.firstToken,
    required this.decode,
    required this.total,
  });

  final int promptTokens;
  final int generatedTokens;
  final StopReason stopReason;

  /// Reading the prompt (prefill).
  final Duration promptEval;

  /// From the `generate` call reaching native code to the first token posted.
  final Duration firstToken;

  /// First token posted to last token posted.
  final Duration decode;

  /// The whole run.
  final Duration total;
}

/// Timings of one generation, as the app sees them.
///
/// Two clocks, on purpose. The `native*` fields are measured inside the worker
/// thread. The others are measured in Dart when the token arrives, so they
/// include the trip through `NativeCallable.listener` and the event loop. The
/// difference between the two is what the bridge costs.
class GenerationStats {
  const GenerationStats({
    required this.promptTokens,
    required this.generatedTokens,
    required this.stopReason,
    required this.timeToFirstToken,
    required this.tokensPerSecond,
    required this.total,
    required this.native,
  });

  final int promptTokens;

  /// Tokens produced (not counting the end-of-text token).
  final int generatedTokens;
  final StopReason stopReason;

  /// From `generate` being listened to until the first token reached Dart.
  /// Includes prompt formatting and the prefill.
  final Duration timeToFirstToken;

  /// Decode speed seen by Dart: (tokens - 1) divided by the time between the
  /// first and the last token arriving. 0 when fewer than two tokens arrived.
  final double tokensPerSecond;

  /// From `generate` being listened to until the stream closed.
  final Duration total;

  /// The worker thread's own numbers.
  final NativeStats native;

  /// Decode speed measured on the worker thread, for comparison with
  /// [tokensPerSecond].
  double get nativeTokensPerSecond {
    final us = native.decode.inMicroseconds;
    return us > 0 && native.generatedTokens > 1
        ? (native.generatedTokens - 1) * 1e6 / us
        : 0;
  }

  @override
  String toString() =>
      'GenerationStats(prompt=$promptTokens, generated=$generatedTokens, '
      'ttft=${timeToFirstToken.inMilliseconds} ms, '
      '${tokensPerSecond.toStringAsFixed(1)} tok/s '
      '(native ${nativeTokensPerSecond.toStringAsFixed(1)} tok/s), '
      'stop=${stopReason.name})';
}
