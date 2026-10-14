// Hand-written dart:ffi bindings for src/llm_bridge.h.
//
// The C surface is ten functions, so there is no ffigen step: this file is the
// whole contract and reads next to the header.
//
// `@Native` looks symbols up in the code asset that hook/build.dart registers
// under the id `package:llm_bridge/src/bindings.dart`, which is this file's own
// library URI. That is why the asset is named `src/bindings.dart` in the hook.

import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// `void (*llb_event_cb)(int64_t stream_id, int32_t event, char* data, int32_t len)`
///
/// Called on a native worker thread. Dart can only receive it through
/// `NativeCallable.listener`, which queues the call on the isolate's event loop.
typedef LlbEventCallbackNative =
    Void Function(Int64 streamId, Int32 event, Pointer<Utf8> data, Int32 len);

/// Event kinds, from `enum` in llm_bridge.h.
const int llbEventToken = 0;
const int llbEventDone = 1;
const int llbEventError = 2;

/// Number of 64-bit fields in `llb_stats`.
const int llbStatsFields = 7;

@Native<Pointer<Utf8> Function()>(symbol: 'llb_version')
external Pointer<Utf8> llbVersion();

@Native<
  Pointer<Void> Function(Pointer<Utf8>, Int32, Int32, Pointer<Utf8>, Int32)
>(symbol: 'llb_load')
external Pointer<Void> llbLoad(
  Pointer<Utf8> path,
  int nCtx,
  int nThreads,
  Pointer<Utf8> err,
  int errLen,
);

@Native<Void Function(Pointer<Void>)>(symbol: 'llb_unload')
external void llbUnload(Pointer<Void> model);

@Native<Pointer<Utf8> Function(Pointer<Void>)>(symbol: 'llb_chat_template')
external Pointer<Utf8> llbChatTemplate(Pointer<Void> model);

@Native<
  Int32 Function(
    Pointer<Void>,
    Pointer<Pointer<Utf8>>,
    Pointer<Pointer<Utf8>>,
    Int32,
    Int32,
    Pointer<Utf8>,
    Int32,
  )
>(symbol: 'llb_chat_format')
external int llbChatFormat(
  Pointer<Void> model,
  Pointer<Pointer<Utf8>> roles,
  Pointer<Pointer<Utf8>> contents,
  int n,
  int addAssistant,
  Pointer<Utf8> out,
  int outLen,
);

@Native<
  Int64 Function(
    Pointer<Void>,
    Pointer<Utf8>,
    Int32,
    Float,
    Uint32,
    Pointer<NativeFunction<LlbEventCallbackNative>>,
  )
>(symbol: 'llb_generate')
external int llbGenerate(
  Pointer<Void> model,
  Pointer<Utf8> prompt,
  int maxTokens,
  double temperature,
  int seed,
  Pointer<NativeFunction<LlbEventCallbackNative>> callback,
);

@Native<Void Function(Pointer<Void>, Int64)>(symbol: 'llb_cancel')
external void llbCancel(Pointer<Void> model, int streamId);

@Native<Void Function(Pointer<Void>, Pointer<Int64>)>(symbol: 'llb_last_stats')
external void llbLastStats(Pointer<Void> model, Pointer<Int64> out);

@Native<Void Function(Pointer<Utf8>)>(symbol: 'llb_free_string')
external void llbFreeString(Pointer<Utf8> s);
