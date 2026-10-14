// Runs the real library against a real model. Skipped unless a model is given:
//
//   LLM_BRIDGE_MODEL=/path/to/qwen2.5-0.5b-instruct-q4_k_m.gguf dart test test/native_smoke_test.dart
//
// The first run compiles llama.cpp through hook/build.dart (minutes).
// Optional: LLM_BRIDGE_THREADS (default 4).

import 'dart:io';

import 'package:llm_bridge/llm_bridge.dart';
import 'package:test/test.dart';

void main() {
  final model = Platform.environment['LLM_BRIDGE_MODEL'];
  final threads =
      int.tryParse(Platform.environment['LLM_BRIDGE_THREADS'] ?? '') ?? 4;
  final skip = model == null || !File(model).existsSync()
      ? 'set LLM_BRIDGE_MODEL to a GGUF file to run this test'
      : null;

  late LlamaTokenGenerator llm;

  setUpAll(() async {
    if (skip != null) return;
    llm = LlamaTokenGenerator();
    await llm.load(modelPath: model!, contextSize: 512, threads: threads);
  });

  tearDownAll(() {
    if (skip == null) llm.dispose();
  });

  test('library version', () {
    expect(FfiLlamaBackend.nativeVersion, contains('llama.cpp b11610'));
  }, skip: skip);

  test('streams several tokens and reports timings', () async {
    final pieces = await llm
        .generate('Name three colours.', maxTokens: 32)
        .toList();
    final stats = llm.lastStats!;
    // ignore: avoid_print
    print('SMOKE: "${pieces.join()}"\nSMOKE: $stats');
    expect(pieces.length, greaterThan(3));
    expect(pieces.join().trim(), isNotEmpty);
    expect(stats.generatedTokens, greaterThan(3));
    expect(stats.tokensPerSecond, greaterThan(0));
    expect(stats.timeToFirstToken, greaterThan(Duration.zero));
  }, skip: skip);

  test('greedy decoding is repeatable', () async {
    final a = (await llm.generate('Say hello.', maxTokens: 16).toList()).join();
    final b = (await llm.generate('Say hello.', maxTokens: 16).toList()).join();
    expect(a, b);
  }, skip: skip);

  test('the chat template of the model is applied', () async {
    final backend = FfiLlamaBackend();
    addTearDown(backend.dispose);
    final handle = await backend.loadModel(
      path: model!,
      contextSize: 64,
      threads: 1,
    );
    addTearDown(() => backend.unloadModel(handle));
    final text = backend.formatChat(handle, const [
      ChatMessage.system('S'),
      ChatMessage.user('U'),
    ], addAssistant: true);
    // Qwen2.5 is ChatML. llama.cpp must agree with our Dart fallback.
    expect(
      text,
      formatChatMl(const [ChatMessage.system('S'), ChatMessage.user('U')]),
    );
  }, skip: skip);

  test('cancel stops generation quickly', () async {
    final received = <String>[];
    final sub = llm
        .generate('Write a very long story.', maxTokens: 400)
        .listen(received.add);
    while (received.length < 3) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final watch = Stopwatch()..start();
    await sub.cancel();
    watch.stop();
    expect(llm.lastStats!.stopReason, StopReason.cancelled);
    expect(received.length, lessThan(400));
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
  }, skip: skip);

  test('a prompt that does not fit is an error, not a crash', () async {
    final long = 'word ' * 2000;
    await expectLater(llm.generate(long), emitsError(isA<StateError>()));
  }, skip: skip);

  test('UTF-8 survives the trip', () async {
    final pieces = await llm
        .generate('Reply with the single emoji for a smile.', maxTokens: 12)
        .toList();
    expect(pieces.join().contains('�'), isFalse);
  }, skip: skip);
}
