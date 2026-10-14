import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'backend.dart';
import 'bindings.dart';
import 'chat.dart';
import 'generation_stats.dart';

/// The real native layer: dart:ffi into `libllm_bridge`.
///
/// The one interesting part is [_callable]. A native worker thread decodes
/// tokens and calls one C function pointer per token. That pointer is a
/// `NativeCallable.listener`: calling it from any thread copies the arguments
/// into a message for this isolate and returns at once. The worker never waits
/// for Dart, and Dart never waits for the worker, so the UI isolate only does a
/// few microseconds of work per token.
class FfiLlamaBackend implements LlamaBackend {
  FfiLlamaBackend() {
    _callable = NativeCallable<LlbEventCallbackNative>.listener(_onNativeEvent)
      // Do not let an idle callable keep a Dart-only program alive.
      ..keepIsolateAlive = false;
    _stats = calloc<Int64>(llbStatsFields);
  }

  late final NativeCallable<LlbEventCallbackNative> _callable;
  late final Pointer<Int64> _stats;
  final Map<int, _Stream> _streams = {};
  bool _disposed = false;

  /// The version string of the loaded library, e.g. `llm_bridge 1 / llama.cpp b11610`.
  static String get nativeVersion => llbVersion().toDartString();

  @override
  Future<int> loadModel({
    required String path,
    required int contextSize,
    required int threads,
  }) async {
    // Loading maps the file and allocates the KV cache: hundreds of
    // milliseconds. A short-lived isolate keeps the UI isolate free.
    final (address, error) = await Isolate.run(() {
      final cPath = path.toNativeUtf8();
      final err = calloc<Uint8>(512).cast<Utf8>();
      try {
        final model = llbLoad(cPath, contextSize, threads, err, 512);
        return (model.address, model == nullptr ? err.toDartString() : null);
      } finally {
        calloc.free(cPath);
        calloc.free(err);
      }
    });
    if (address == 0) throw StateError(error ?? 'llb_load failed');
    return address;
  }

  @override
  String? formatChat(
    int model,
    List<ChatMessage> messages, {
    required bool addAssistant,
  }) {
    final handle = Pointer<Void>.fromAddress(model);
    final n = messages.length;
    final roles = calloc<Pointer<Utf8>>(n);
    final contents = calloc<Pointer<Utf8>>(n);
    final allocated = <Pointer<Utf8>>[];
    try {
      for (var i = 0; i < n; i++) {
        roles[i] = messages[i].role.toNativeUtf8();
        contents[i] = messages[i].content.toNativeUtf8();
        allocated
          ..add(roles[i])
          ..add(contents[i]);
      }
      final add = addAssistant ? 1 : 0;
      // First call sizes the result, second fills it.
      final size = llbChatFormat(handle, roles, contents, n, add, nullptr, 0);
      if (size < 0) return null;
      final out = calloc<Uint8>(size + 1).cast<Utf8>();
      try {
        final written = llbChatFormat(
          handle,
          roles,
          contents,
          n,
          add,
          out,
          size + 1,
        );
        if (written < 0) return null;
        return utf8.decode(
          out.cast<Uint8>().asTypedList(written),
          allowMalformed: true,
        );
      } finally {
        calloc.free(out);
      }
    } finally {
      allocated.forEach(calloc.free);
      calloc.free(roles);
      calloc.free(contents);
    }
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
    if (_disposed) throw StateError('backend is disposed');
    final cPrompt = prompt.toNativeUtf8();
    try {
      final id = llbGenerate(
        Pointer<Void>.fromAddress(model),
        cPrompt, // the native side copies it
        maxTokens,
        temperature,
        seed,
        _callable.nativeFunction,
      );
      if (id == -1) throw StateError('a generation is already running');
      if (id < 0) {
        throw ArgumentError('llb_generate rejected its arguments ($id)');
      }
      // Safe to register after the call: events are delivered on this
      // isolate's event loop, which cannot run before this method returns.
      _streams[id] = _Stream(model, onEvent);
      return id;
    } finally {
      calloc.free(cPrompt);
    }
  }

  /// Runs on this isolate's event loop for every message the worker posted.
  void _onNativeEvent(int streamId, int event, Pointer<Utf8> data, int len) {
    String? text;
    if (data != nullptr) {
      // The worker handed us a malloc'd copy; we own it and must free it.
      text = utf8.decode(
        data.cast<Uint8>().asTypedList(len),
        allowMalformed: true,
      );
      llbFreeString(data);
    }
    final stream = _streams[streamId];
    if (stream == null) return; // cancelled and forgotten, or backend disposed
    switch (event) {
      case llbEventToken:
        stream.onEvent(LlamaTokenEvent(text ?? ''));
      case llbEventDone:
        _streams.remove(streamId);
        llbLastStats(Pointer<Void>.fromAddress(stream.model), _stats);
        stream.onEvent(LlamaDoneEvent(_readStats()));
      case llbEventError:
        _streams.remove(streamId);
        stream.onEvent(LlamaErrorEvent(text ?? 'unknown error'));
    }
  }

  NativeStats _readStats() {
    Duration us(int i) => Duration(microseconds: _stats[i]);
    return NativeStats(
      promptTokens: _stats[0],
      generatedTokens: _stats[1],
      stopReason: StopReason.fromNative(_stats[2]),
      promptEval: us(3),
      firstToken: us(4),
      decode: us(5),
      total: us(6),
    );
  }

  @override
  void cancel(int model, int streamId) =>
      llbCancel(Pointer<Void>.fromAddress(model), streamId);

  @override
  void unloadModel(int model) {
    // Joins the worker thread; it checks for cancellation between tokens, so
    // this takes at most one token's time.
    llbUnload(Pointer<Void>.fromAddress(model));
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _streams.clear();
    // Only after every model is unloaded: no worker can call the pointer now.
    _callable.close();
    calloc.free(_stats);
  }
}

class _Stream {
  _Stream(this.model, this.onEvent);
  final int model;
  final void Function(LlamaEvent event) onEvent;
}
