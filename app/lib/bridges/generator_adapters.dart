// Two token generators behind one interface: the C demo generator (no model,
// shows NativeCallable.listener on its own) and the real LLM (llama.cpp).
// Both stream tokens from a native thread into Dart through dart:ffi.

import 'dart:io';

import 'package:ffi_bridge/ffi_bridge.dart';
import 'package:llm_bridge/llm_bridge.dart';
import 'package:path_provider/path_provider.dart';

import 'bridge.dart';

class DemoGeneratorAdapter implements TokenGenerator {
  final DemoTokenGenerator _generator = DemoTokenGenerator();

  @override
  String get label => 'Demo generator';

  @override
  bool get isRealModel => false;

  @override
  Future<void> load() async {}

  @override
  Stream<String> generate(String prompt, {int maxTokens = 128}) =>
      _generator.generate(prompt, maxTokens: maxTokens);

  @override
  Future<void> cancel() => _generator.cancel();

  @override
  void dispose() => _generator.dispose();
}

/// The GGUF file name scripts/fetch-models.sh downloads.
const llmModelFileName = 'qwen2.5-0.5b-instruct-q4_k_m.gguf';

/// Where the app looks for the model, first match wins (docs/LLM.md):
/// Android: external files dir + `/models/`, where `fetch-models.sh --push`
/// puts it. iOS: Documents + `/models/`, or Documents itself, where a Finder
/// drag lands.
Future<List<File>> llmModelCandidates() async {
  if (Platform.isAndroid) {
    final dir = await getExternalStorageDirectory();
    return [if (dir != null) File('${dir.path}/models/$llmModelFileName')];
  }
  final docs = await getApplicationDocumentsDirectory();
  return [
    File('${docs.path}/models/$llmModelFileName'),
    File('${docs.path}/$llmModelFileName'),
  ];
}

class LlamaGeneratorAdapter implements TokenGenerator {
  LlamaGeneratorAdapter({this.threads = 4});

  final int threads;
  final LlamaTokenGenerator _generator = LlamaTokenGenerator(
    label: 'Qwen2.5 0.5B',
  );

  @override
  String get label => 'LLM (Qwen2.5 0.5B)';

  @override
  bool get isRealModel => true;

  /// Timings of the last generation, from llama.cpp and from Dart.
  GenerationStats? get lastStats => _generator.lastStats;

  @override
  Future<void> load() async {
    if (_generator.isLoaded) return;
    final candidates = await llmModelCandidates();
    final file = candidates.where((f) => f.existsSync()).firstOrNull;
    if (file == null) {
      throw StateError(
        'Model file not found. Run scripts/fetch-models.sh, then copy it to '
        'the phone (see docs/LLM.md). Looked in: '
        '${candidates.map((f) => f.path).join(', ')}',
      );
    }
    await _generator.load(modelPath: file.path, threads: threads);
  }

  @override
  Stream<String> generate(String prompt, {int maxTokens = 128}) =>
      _generator.generate(prompt, maxTokens: maxTokens);

  @override
  Future<void> cancel() => _generator.cancel();

  @override
  void dispose() => _generator.dispose();
}
