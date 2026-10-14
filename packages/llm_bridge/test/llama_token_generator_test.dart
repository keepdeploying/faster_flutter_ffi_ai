import 'dart:async';

import 'package:llm_bridge/llm_bridge.dart';
import 'package:test/test.dart';

import 'fake_backend.dart';

void main() {
  late FakeBackend backend;
  late LlamaTokenGenerator llm;

  Future<void> loadDefault() => llm.load(modelPath: '/models/tiny.gguf');

  setUp(() {
    backend = FakeBackend();
    llm = LlamaTokenGenerator(backend: backend);
  });

  tearDown(() => llm.dispose());

  test('the shape the app adapter relies on', () {
    expect(llm.isRealModel, isTrue);
    expect(llm.label, 'llama.cpp');
    expect(llm.isLoaded, isFalse);
    expect(llm.lastStats, isNull);
  });

  group('load', () {
    test('passes the path and marks the generator loaded', () async {
      await loadDefault();
      expect(backend.loadedPaths, ['/models/tiny.gguf']);
      expect(llm.isLoaded, isTrue);
    });

    test('a failing load throws and leaves it unloaded', () async {
      backend.failLoad = true;
      await expectLater(loadDefault(), throwsStateError);
      expect(llm.isLoaded, isFalse);
    });

    test('loading again unloads the first model', () async {
      await loadDefault();
      await loadDefault();
      expect(backend.unloaded, [100]);
      expect(backend.loadedPaths, hasLength(2));
    });

    test('rejects nonsense arguments before touching native code', () {
      expect(
        () => llm.load(modelPath: 'x', contextSize: 4),
        throwsArgumentError,
      );
      expect(() => llm.load(modelPath: 'x', threads: 0), throwsArgumentError);
      expect(backend.loadedPaths, isEmpty);
    });
  });

  group('chat template', () {
    test(
      'wraps the prompt as system + user using the backend formatter',
      () async {
        await loadDefault();
        await llm.generate('What is FFI?').drain<void>();
        expect(
          backend.prompts.single,
          '[system] You are a helpful assistant.\n[user] What is FFI?\n[assistant] ',
        );
      },
    );

    test(
      'falls back to ChatML when llama.cpp does not know the template',
      () async {
        backend.template = null;
        await loadDefault();
        await llm.generate('Hi').drain<void>();
        expect(
          backend.prompts.single,
          '<|im_start|>system\nYou are a helpful assistant.<|im_end|>\n'
          '<|im_start|>user\nHi<|im_end|>\n'
          '<|im_start|>assistant\n',
        );
      },
    );

    test('systemPrompt: null sends the user message alone', () async {
      backend.template = null;
      await llm.load(modelPath: 'x', systemPrompt: null);
      await llm.generate('Hi').drain<void>();
      expect(
        backend.prompts.single,
        '<|im_start|>user\nHi<|im_end|>\n<|im_start|>assistant\n',
      );
    });

    test('maxTokens and temperature reach the native layer', () async {
      await llm.load(modelPath: 'x', temperature: 0.7);
      await llm.generate('Hi', maxTokens: 2).drain<void>();
      expect(backend.maxTokensSeen, [2]);
      expect(backend.temperaturesSeen, [0.7]);
    });
  });

  group('streaming', () {
    test('delivers the pieces in order and then closes', () async {
      await loadDefault();
      final pieces = await llm.generate('Hi').toList();
      expect(pieces, ['Hello', ',', ' world', '!']);
    });

    test('is lazy: nothing starts until someone listens', () async {
      await loadDefault();
      llm.generate('Hi');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(backend.prompts, isEmpty);
    });

    test('maxTokens stops the stream early and says why', () async {
      await loadDefault();
      final pieces = await llm.generate('Hi', maxTokens: 2).toList();
      expect(pieces, ['Hello', ',']);
      expect(llm.lastStats!.stopReason, StopReason.maxTokens);
    });

    test('records timings and calls onStats', () async {
      final seen = <GenerationStats>[];
      llm = LlamaTokenGenerator(backend: backend, onStats: seen.add);
      await loadDefault();
      await llm.generate('Hi').drain<void>();
      final stats = llm.lastStats!;
      expect(seen, [stats]);
      expect(stats.generatedTokens, 4);
      expect(stats.promptTokens, 12);
      expect(stats.stopReason, StopReason.endOfText);
      expect(stats.timeToFirstToken, greaterThan(Duration.zero));
      expect(stats.total, greaterThanOrEqualTo(stats.timeToFirstToken));
      // 3 intervals of ~5 ms: well under 1000 tok/s, well over 10.
      expect(stats.tokensPerSecond, inInclusiveRange(10, 1000));
      expect(stats.native.generatedTokens, 4);
      expect(stats.nativeTokensPerSecond, closeTo(200, 1));
    });

    test('a native error becomes a stream error', () async {
      backend.errorToEmit = 'llama_decode failed';
      await loadDefault();
      await expectLater(
        llm.generate('Hi'),
        emitsError(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('llama_decode'),
          ),
        ),
      );
    });

    test('generate before load is a stream error, not a crash', () async {
      await expectLater(llm.generate('Hi'), emitsError(isA<StateError>()));
    });
  });

  group('cancel', () {
    test('cancel() stops the native thread and closes the stream', () async {
      backend.pieces = List.generate(100, (i) => 't$i');
      await loadDefault();
      final received = <String>[];
      final done = Completer<void>();
      llm
          .generate('Hi', maxTokens: 100)
          .listen(received.add, onDone: done.complete);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await llm.cancel();
      await done.future.timeout(const Duration(seconds: 2));
      expect(received, isNotEmpty);
      expect(received.length, lessThan(100));
      expect(backend.cancelled, hasLength(1));
      expect(llm.lastStats!.stopReason, StopReason.cancelled);
    });

    test('cancelling the subscription waits for the native thread', () async {
      backend.pieces = List.generate(100, (i) => 't$i');
      await loadDefault();
      final sub = llm.generate('Hi', maxTokens: 100).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await sub.cancel();
      // The fake would throw "already running" if the thread were still alive.
      final next = await llm.generate('Again', maxTokens: 1).toList();
      expect(next, ['t0']);
    });

    test('no tokens reach the listener after cancel()', () async {
      backend.pieces = List.generate(100, (i) => 't$i');
      await loadDefault();
      var afterCancel = 0;
      var cancelled = false;
      llm.generate('Hi', maxTokens: 100).listen((_) {
        if (cancelled) afterCancel++;
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final pending = llm.cancel();
      cancelled = true;
      await pending;
      expect(afterCancel, 0);
    });

    test('cancel() with nothing running is a no-op', () async {
      await loadDefault();
      await llm.cancel();
      expect(backend.cancelled, isEmpty);
    });

    test('a new generate cancels the running one and waits for it', () async {
      backend.pieces = List.generate(50, (i) => 't$i');
      await loadDefault();
      final first = <String>[];
      final firstDone = Completer<void>();
      llm
          .generate('one', maxTokens: 50)
          .listen(first.add, onDone: firstDone.complete);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      backend.pieces = ['a', 'b'];
      final second = await llm.generate('two', maxTokens: 50).toList();

      expect(second, ['a', 'b']);
      expect(firstDone.isCompleted, isTrue);
      expect(first.length, lessThan(50));
      expect(backend.prompts, hasLength(2));
    });

    test('three queued generations run strictly one after another', () async {
      backend.pieces = List.generate(20, (i) => 't$i');
      await loadDefault();
      final results = <int, List<String>>{};
      final futures = [
        for (var i = 0; i < 3; i++)
          llm
              .generate('q$i', maxTokens: 2)
              .toList()
              .then((r) => results[i] = r),
      ];
      await Future.wait(futures).timeout(const Duration(seconds: 5));
      // No "already running" errors; the last one always completes in full.
      expect(results[2], ['t0', 't1']);
    });
  });

  group('dispose', () {
    test('unloads the model and the backend once', () async {
      await loadDefault();
      llm.dispose();
      llm.dispose();
      expect(backend.unloaded, [100]);
      expect(backend.disposeCalls, 1);
    });

    test('closes a stream that is still running', () async {
      backend.pieces = List.generate(100, (i) => 't$i');
      await loadDefault();
      final done = Completer<void>();
      llm.generate('Hi', maxTokens: 100).listen((_) {}, onDone: done.complete);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      llm.dispose();
      await done.future.timeout(const Duration(seconds: 2));
    });

    test('using it afterwards fails loudly', () async {
      llm.dispose();
      expect(() => llm.generate('Hi'), throwsStateError);
      expect(() => loadDefault(), throwsStateError);
    });
  });
}
