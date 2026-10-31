// Token generators behind one interface. Three paths:
//   * SmolLM2 135M, bundled in the APK/IPA and loaded through llama.cpp over
//     Dart FFI. Always available on any install.
//   * Qwen2.5 0.5B through llama.cpp over Dart FFI (the "FFI LLM" segment).
//   * Qwen2.5 0.5B through llama.cpp over a platform channel ("Channel LLM"
//     segment). Same model, same tokens, only the bridge differs.
//
// The C canned-text demo generator (DemoGeneratorAdapter) is retained for
// anyone studying NativeCallable.listener but is not wired into the Generate
// screen.

import 'dart:io';

import 'package:channel_bridge/channel_bridge.dart';
import 'package:ffi_bridge/ffi_bridge.dart';
import 'package:llm_bridge/llm_bridge.dart';
import 'package:path_provider/path_provider.dart';

import '../services/bundled_model.dart';
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

/// Where the app looks for the Qwen GGUF, first match wins (docs/LLM.md):
///
/// * Android: external files dir + `/models/` (adb push target from
///   `scripts/fetch-models.sh --push` on Pixel-class devices), AND app
///   documents + `/models/` (Transsion-style FUSE workaround + in-app
///   Download button). Both are checked so either workflow lands somewhere
///   the loader sees.
/// * iOS: documents + `/models/`, or documents itself, where a Finder drag
///   or the in-app Download lands.
Future<List<File>> llmModelCandidates() async {
  if (Platform.isAndroid) {
    final ext = await getExternalStorageDirectory();
    final docs = await getApplicationDocumentsDirectory();
    return [
      if (ext != null) File('${ext.path}/models/$llmModelFileName'),
      File('${docs.path}/models/$llmModelFileName'),
    ];
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

/// SmolLM2 135M Instruct Q4_K_M shipped as a Flutter asset. On first launch
/// the gguf is copied into the app's Documents directory so llama.cpp can mmap
/// it from a filesystem path; later launches reuse the copy.
class BundledSmolGeneratorAdapter implements TokenGenerator {
  BundledSmolGeneratorAdapter({this.threads = 4});

  final int threads;
  final LlamaTokenGenerator _generator = LlamaTokenGenerator(
    label: 'SmolLM2 135M',
  );

  @override
  String get label => 'SmolLM2 135M (bundled)';

  @override
  bool get isRealModel => true;

  /// Timings of the last generation, from llama.cpp and from Dart.
  GenerationStats? get lastStats => _generator.lastStats;

  @override
  Future<void> load() async {
    if (_generator.isLoaded) return;
    final path = await ensureBundledSlmReady();
    await _generator.load(modelPath: path, threads: threads);
  }

  @override
  Stream<String> generate(String prompt, {int maxTokens = 128}) =>
      _generator.generate(prompt, maxTokens: maxTokens);

  @override
  Future<void> cancel() => _generator.cancel();

  @override
  void dispose() => _generator.dispose();
}

/// Qwen2.5 0.5B through llama.cpp **over a platform channel**: Kotlin or Swift
/// loads the same `libllm_bridge` native library the FFI path uses, calls the
/// same functions, and streams tokens back over an EventChannel. Paired with
/// [LlamaGeneratorAdapter] it demonstrates "same model, only the bridge
/// differs" for text generation.
class ChannelLlamaGeneratorAdapter implements TokenGenerator {
  ChannelLlamaGeneratorAdapter({this.threads = 4});

  final int threads;
  final ChannelLlamaGenerator _generator = ChannelLlamaGenerator();
  String? _modelPath;

  @override
  String get label => 'Channel LLM (Qwen2.5 0.5B)';

  @override
  bool get isRealModel => true;

  @override
  Future<void> load() async {
    if (_modelPath != null) return;
    final candidates = await llmModelCandidates();
    final file = candidates.where((f) => f.existsSync()).firstOrNull;
    if (file == null) {
      final tried = candidates.isEmpty
          ? '(no candidate paths)'
          : candidates.map((f) => '\n  - ${f.path}').join();
      throw StateError(
        'LLM model file $llmModelFileName not found. Download it from the '
        'LLM model page, or push it over adb. Checked:$tried',
      );
    }
    _modelPath = file.path;
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

/// SmolLM2 135M bundled with the APK, streamed through the **same** platform
/// channel as [ChannelLlamaGeneratorAdapter]. Lets the Generate screen offer
/// Channel for both models, so a user can compare bridges on either size.
class ChannelBundledSmolAdapter implements TokenGenerator {
  ChannelBundledSmolAdapter({this.threads = 4});

  final int threads;
  final ChannelLlamaGenerator _generator = ChannelLlamaGenerator();
  String? _modelPath;

  @override
  String get label => 'Channel SmolLM2 135M (bundled)';

  @override
  bool get isRealModel => true;

  @override
  Future<void> load() async {
    if (_modelPath != null) return;
    final path = await ensureBundledSlmReady();
    _modelPath = path;
    await _generator.load(modelPath: path, threads: threads);
  }

  @override
  Stream<String> generate(String prompt, {int maxTokens = 128}) =>
      _generator.generate(prompt, maxTokens: maxTokens);

  @override
  Future<void> cancel() => _generator.cancel();

  @override
  void dispose() => _generator.dispose();
}

/// The two choices the Generate screen offers on the Model axis.
enum GenerateModel {
  smol('SmolLM2 135M'),
  qwen('Qwen2.5 0.5B');

  const GenerateModel(this.label);
  final String label;
}

/// The two choices on the Bridge axis.
enum GenerateBridge {
  ffi('FFI'),
  channel('Channel');

  const GenerateBridge(this.label);
  final String label;
}

/// Builds the right [TokenGenerator] for a (model, bridge) pair. Mirrors the
/// `classifierAt(kind, site)` factory in [AppServices].
typedef GeneratorAt =
    TokenGenerator Function(GenerateModel model, GenerateBridge bridge);

TokenGenerator defaultGeneratorAt(
  GenerateModel model,
  GenerateBridge bridge,
) {
  return switch ((model, bridge)) {
    (GenerateModel.smol, GenerateBridge.ffi) => BundledSmolGeneratorAdapter(),
    (GenerateModel.smol, GenerateBridge.channel) => ChannelBundledSmolAdapter(),
    (GenerateModel.qwen, GenerateBridge.ffi) => LlamaGeneratorAdapter(),
    (GenerateModel.qwen, GenerateBridge.channel) =>
      ChannelLlamaGeneratorAdapter(),
  };
}
