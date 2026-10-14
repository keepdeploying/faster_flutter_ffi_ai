# ffi_bridge

The FFI half of the "Faster Flutter: Accessing On-Device AI with Dart FFI"
demo. It is a `package_ffi` package: a small C library, a build hook that
compiles it, and a thin Dart API on top. The app never imports `dart:ffi`
itself; it wraps these classes in adapters for its own `PayloadBridge`,
`Preprocessor` and `TokenGenerator` interfaces.

Same model, same input, same phone; only the bridge differs. This package is
the "FFI" side of that comparison.

## What is in it

| Path | What it is |
| --- | --- |
| `src/ffi_bridge.c`, `.h` | The C code. Every function is prefixed `ffb_`. |
| `hook/build.dart` | The build hook (`package:hooks` + `native_toolchain_c`). |
| `ffigen.yaml` | Config that turns the header into Dart bindings. |
| `lib/ffi_bridge_bindings_generated.dart` | Generated `@Native` bindings. Do not edit. |
| `lib/ffi_bridge_leaf_bindings.dart` | Hand-written leaf binding of `ffb_checksum`. |
| `lib/ffi_bridge.dart` | The public API. |
| `test/ffi_bridge_test.dart` | Tests that run the real C code. |

## The C API

```c
uint32_t ffb_checksum(const uint8_t* data, size_t len);   // byte sum mod 2^32, leaf-safe
uint8_t* ffb_alloc(size_t len);  void ffb_free(uint8_t* p);
void ffb_preprocess_rgba(const uint8_t* rgba, int32_t w, int32_t h,
                         float* out, int32_t size);       // bilinear, [-1, 1]
int64_t ffb_demo_generate(const char* prompt, int32_t max_tokens, int32_t delay_ms,
                          void (*on_token)(int64_t stream_id, const char* token));
void ffb_demo_cancel(int64_t stream_id);
```

The demo generator starts a pthread that calls `on_token` once per token of a
fixed paragraph about on-device AI (the prompt is ignored), waiting `delay_ms`
between tokens, then calls it once with `NULL` to say the stream is over. A
cancelled stream also ends with that `NULL`. Token strings are native-owned,
static, and never freed, so a pointer stays valid even if Dart reads it a
moment later. Dart copies it with `toDartString` straight away.

## The Dart API

```dart
enum FfiPayloadMode { copy, leaf, zeroCopy }

class FfiPayloadBridge {
  FfiPayloadBridge(FfiPayloadMode mode);
  Future<void> warmUp(int maxBytes);
  int roundTrip(Uint8List payload);
  Uint8List get nativeView;          // zeroCopy only: a view onto native memory
  int roundTripNative(int length);   // zeroCopy only
  void dispose();
}

class NativePreprocessor {
  Float32List preprocess(Uint8List rgba, int width, int height, {int size = 224});
  void preprocessInto(Uint8List rgba, int width, int height, Float32List out,
      {int size = 224});
  Float32List allocateOutput({int size = 224});  // native-backed output list
  void dispose();
}

class DemoTokenGenerator {
  Stream<String> generate(String prompt,
      {int maxTokens = 128, Duration delay = const Duration(milliseconds: 25)});
  Future<void> cancel();
  void dispose();
}
```

What each payload mode costs:

* **copy**: one copy of the payload into a native buffer made at `warmUp`, then
  a normal FFI call. Cost grows with the payload. Safe for any native function.
* **leaf**: no copy and no VM transition; Dart passes the `Uint8List` itself.
  Cheapest for small payloads, with the strict rules below.
* **zeroCopy**: the bytes already live in native memory. Fill `nativeView` once;
  each `roundTrip` then passes only a pointer and a length.

`NativePreprocessor` keeps its input and output buffers between calls and
returns a copy of the result. `preprocessInto` writes into a list from
`allocateOutput` with no extra copy.

`DemoTokenGenerator` uses `NativeCallable.listener`: the native thread posts
each token to the isolate's event loop and carries on, so the UI thread never
waits on it. The callable is closed when the stream ends or is cancelled.
`cancel()` completes once the native end marker has arrived.

Native memory is released by `dispose()`, and by a `NativeFinalizer` if you
forget.

## How the build hook works

There is no `CMakeLists.txt`, podspec or Gradle file. When you run
`flutter build`, `flutter run` or `dart test`, the tool finds `hook/build.dart`
and runs it. The hook asks `native_toolchain_c` to compile `src/ffi_bridge.c`
with the C compiler of the target platform (clang on Linux, Android NDK clang,
Xcode clang on iOS and macOS) into a shared library, and registers that library
as a "code asset" with the id `package:ffi_bridge/ffi_bridge_bindings_generated.dart`.
At run time the `@Native` annotations in the Dart bindings resolve their symbols
against that asset. The result is the same on a laptop test run and on a phone.

Requirements: a C compiler on the machine that builds (clang on Linux; Xcode
for iOS and macOS; the Android NDK, which Flutter installs, for Android).
Windows is not supported: the demo generator needs pthreads.

Regenerate the bindings after changing the header with
`dart run ffigen --config ffigen.yaml` (needs libclang). Keep new leaf bindings
in `lib/ffi_bridge_leaf_bindings.dart`, so regeneration never removes them.

## Leaf calls and their limits

A leaf call (`@Native(isLeaf: true)`) is a call that skips the work Dart does
when it hands control to native code: it does not mark the isolate as "in
native" and does not give the garbage collector a chance to run. That makes it
very cheap, and it lets you pass a `Uint8List` as `list.address` without
copying it. The price is a strict contract. The native function must be short,
it must not block (no locks, no I/O, no sleeping), and it must never call back
into Dart. While it runs, the garbage collector cannot stop that thread, so a
long call stalls garbage collection for the whole isolate group, not only for
the isolate that made the call (see the `dart:ffi` documentation for
`Native.isLeaf`). `ffb_checksum` qualifies for small payloads. An 8 MB sum is
already long enough that a normal call is the safer choice, and the preprocess
and the token generator must never be leaf calls.

## Checks

```sh
dart test
dart analyze
dart format --set-exit-if-changed .
```

Android and iOS builds are checked on a Mac with the app's bench scripts.
