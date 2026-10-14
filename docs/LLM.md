# On-device LLM

The "Generate text" screen can run a real model, not only the C demo
generator. This file says what runs, why it was chosen, how to set it up on each
phone, and what has and has not been checked. Facts below were read from the
packages' own source (archives from pub.dev) on 2026-10-14, not from search
snippets.

## Decision

**Our own thin package, `packages/llm_bridge`, with a build hook that compiles
llama.cpp from one pinned commit.** No pub LLM package, no prebuilt binaries.

- llama.cpp tag `b11610`, commit `091b6a7fc561b78da90a0ed2d524ec995458c657`.
  The hook fetches exactly that commit with git (shallow, sparse, cached) and
  refuses to build if `HEAD` differs. A commit id is a content hash, so this is
  the same guarantee as a pinned checksum, without trusting a binary.
- CMake and the platform compiler (NDK for Android, Xcode clang for iOS) build
  one shared library per ABI: llama.cpp, ggml and our wrapper linked together.
- Flutter bundles the library as a code asset. `flutter run` is all the user
  types. No framework dragging in Xcode, no Gradle edits, no `Podfile` edits.
- Tokens reach Dart exactly as the talk says: a native worker thread decodes
  and calls one function pointer per token; that pointer is a
  `NativeCallable.listener`, so the call is queued on the Dart isolate and the
  worker never waits for Dart.

Why not a prebuilt-binary hook (the Flutter "closed-source library" pattern)?
That pattern is right when you cannot build the code. Here we can, and a
prebuilt path has three problems today: nobody publishes a hash-pinned set of
Android arm64 and iOS dynamic libraries we can verify (llama.cpp's official
release has an iOS *static* XCFramework, and I found no supported way to ship static code as a Flutter code asset),
the third-party sets that exist add a trust step and a version-pairing
puzzle, and none of them delivers tokens with `NativeCallable.listener`.
The trade-off we accept is a first build of a few minutes and a CMake install.

### What the user needs on the Mac

| Need | Why | How |
| --- | --- | --- |
| Xcode (already needed for iOS) | clang, iPhone SDK | App Store |
| `cmake` | builds llama.cpp | `brew install cmake` (or Android Studio, SDK Manager, SDK Tools, CMake) |
| `ninja` (optional) | faster build | `brew install ninja` |
| Android NDK (Android only) | cross compiler | Android Studio, SDK Manager, SDK Tools, "NDK (Side by side)" |
| `git` and network on the first build | fetches llama.cpp | Xcode command line tools |

`scripts/setup.sh` (owned elsewhere) should check for `cmake` and print the
`brew` line if it is missing.

## Alternatives considered

| Option | Verdict |
| --- | --- |
| [`llamadart` 0.12.0](https://pub.dev/packages/llamadart) (MIT, published 2026-10-14) | The strongest package. Build hook downloads pinned, SHA-256 checked prebuilt libraries from `leehack/llamadart-native`; Android arm64 and iOS (Metal) supported. Rejected as the default because: iOS needs a SwiftPM companion package whose version must match the core exactly; the 2,600-line hook and three native repos are a lot to trust and to explain; releases change fast (0.6 to 0.12 in a few months); tokens come through a worker isolate, not a native thread with `NativeCallable.listener`. **It is the fallback** (see below). |
| [`llama_cpp_dart` 0.2.2](https://pub.dev/packages/llama_cpp_dart) (MIT) and its [0.9 line](https://github.com/netdur/llama_cpp_dart) | 0.2.2 has no hook: you compile llama.cpp yourself and place the library. The 0.9 line adds a hook for Android CPU libraries only; Apple goes through SwiftPM/XCFramework. Isolate-based streaming. Not on pub as stable yet. |
| [`fllamer` 0.2.2](https://pub.dev/packages/fllamer) | **GPL-3.0**, which would force the whole app to be GPL. Hook is marked experimental, iOS device smoke tests "not yet done", 37 downloads. No. |
| [`llm_llamacpp` 0.7.0](https://pub.dev/packages/llm_llamacpp) (MIT) | Hook downloads a prebuilt zip from GitHub releases keyed by an ABI fingerprint, but I found no checksum verification in the hook, and a pub.dev install has no build-from-source fallback. Isolates, not a native thread. Requires Dart 3.12+. No. |
| [`flutter_local_llm` 1.0.0](https://pub.dev/packages/flutter_local_llm) (MIT) | Claims `NativeCallable.listener` and native assets, which is exactly our design. But the published archive contains no llama.cpp sources or fetch step (its wrapper includes `llama.h`, which is not there), and its hook lives in `hooks/` while Dart only runs `hook/`. I could not make it build from what is published. No. |
| llama.cpp's official release binaries ([releases](https://github.com/ggml-org/llama.cpp/releases)) | Android arm64 tarball of CLI tools; iOS static XCFramework. Static code is not something Flutter bundles as a code asset, and I could not fetch the assets to pin hashes. No. |
| Platform channels to Kotlin/Swift LLM runtimes | Defeats the point of the talk (FFI). Only the classifier uses channels, for the comparison. |

**Fallback if CMake on the Mac is not acceptable:** depend on `llamadart` and
write a 40-line adapter over its `LlamaEngine.generate` stream. The app only
sees the `TokenGenerator` interface, so nothing else changes. The cost: the
talk's "native thread posts to a listener" story for LLM tokens is then told
with the C demo generator only.

## What `llm_bridge` is

```text
packages/llm_bridge/
  hook/build.dart       fetch pinned llama.cpp, run CMake, register the code asset
  src/llm_bridge.h      the C ABI (10 functions), read this first
  src/llm_bridge.cpp    worker thread, decode loop, UTF-8 safe token pieces
  src/CMakeLists.txt    llama.cpp + wrapper -> one shared library, CPU only
  lib/src/bindings.dart hand-written @Native bindings
  lib/src/ffi_backend.dart   NativeCallable.listener, ownership of token strings
  lib/src/llama_token_generator.dart   the public class
  test/                 fake-backend unit tests + real-model smoke test
  example/generate.dart CLI: streams, prints ttft, tok/s, event-loop gaps
```

### Public API

```dart
class LlamaTokenGenerator {
  LlamaTokenGenerator({LlamaBackend? backend, String label, void Function(GenerationStats)? onStats});
  String get label;
  bool get isRealModel;            // true
  bool get isLoaded;
  GenerationStats? get lastStats;  // timings of the last generation
  Future<void> load({required String modelPath, int contextSize = 1024, int threads = 4,
                     String? systemPrompt = 'You are a helpful assistant.',
                     double temperature = 0 /* greedy, repeatable */, int seed = 0});
  Stream<String> generate(String prompt, {int maxTokens = 128});
  Future<void> cancel();
  void dispose();
}
```

`GenerationStats` has `promptTokens`, `generatedTokens`, `stopReason`,
`timeToFirstToken` and `tokensPerSecond` (both measured in Dart when tokens
arrive), plus `native` (the worker thread's own clock) and
`nativeTokensPerSecond`. The gap between the two is the cost of the bridge.

Behaviour worth knowing:

- `generate` is lazy: nothing starts until the stream is listened to.
- Cancelling the subscription or calling `cancel()` stops the native thread
  (it also aborts a long prefill) and `await` returns once the thread is done.
- A new `generate` cancels the running one and waits for it.
- Native errors arrive as stream errors (`StateError`).
- The chat template comes from the model file, applied by llama.cpp's own
  `llama_chat_apply_template`. If llama.cpp does not know the template, a Dart
  ChatML formatter is used (`formatChatMl`). The smoke test checks that the two
  agree for Qwen2.5.
- Greedy decoding by default: same prompt, same answer, which a benchmark needs.
- The KV cache is cleared for every `generate`, so runs do not depend on history.

### App adapter (about 10 lines, lives in `app/lib/bridges/`)

```dart
class LlmTokenGenerator implements TokenGenerator {
  LlmTokenGenerator(this._modelPath);
  final String _modelPath;
  final _llm = LlamaTokenGenerator();
  @override String get label => 'llama.cpp (Qwen2.5 0.5B)';
  @override bool get isRealModel => true;
  @override Future<void> load() => _llm.load(modelPath: _modelPath);
  @override Stream<String> generate(String p, {int maxTokens = 128}) => _llm.generate(p, maxTokens: maxTokens);
  @override Future<void> cancel() => _llm.cancel();
  @override void dispose() => _llm.dispose();
}
```

For the results file, read `_llm.lastStats` after the stream closes:
`timeToFirstToken` becomes `firstTokenMs`, `tokensPerSecond` is `tokensPerSec`.

### How a token travels

1. Dart calls `llb_generate` (a normal FFI call, microseconds) and gets a stream id.
2. A `std::thread` tokenizes, prefills, then loops: sample, convert to text,
   decode the next token. For each piece it `malloc`s a copy and calls the
   callback pointer.
3. The pointer is `NativeCallable.listener`: any thread may call it; the call is
   posted to the isolate that created it and returns at once.
4. On the Dart event loop `_onNativeEvent` decodes the UTF-8, calls
   `llb_free_string` (Dart owns the copy; it has to be a copy because Dart runs
   later), and pushes the text into the stream.

One callable serves the whole generator and is closed in `dispose()` after the
worker has been joined, so no thread can call a closed callable.

## The model

| | |
| --- | --- |
| Model | [Qwen2.5-0.5B-Instruct](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF), Q4_K_M |
| File | `qwen2.5-0.5b-instruct-q4_k_m.gguf`, 491,400,032 bytes (469 MiB) |
| SHA-256 | `74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db` |
| Licence | Apache-2.0 (model card and `LICENSE` in the repo). No gate, no login. |
| Pinned revision | Hugging Face commit `9217f5db79a29953eb74d5343926648285ec7e67` |
| Template | ChatML, which llama.cpp knows |

Why this one: Apache-2.0 and ungated (Gemma 3 needs accepting Google's terms,
Llama 3.2 has its own community licence), small enough for any phone with 3 GB
of free RAM (about 600 MB resident with a 1024-token context), strong enough to
give readable answers on stage, and the ChatML template is the simplest to
show. Q4_K_M is the usual size/quality point. If a phone is slow, the same
repo has `q4_0` (429 MB), which llama.cpp repacks for ARM at load time; change
the three constants at the top of `scripts/fetch-models.sh` (the checksum for
each file is listed on the Hugging Face file page).

Get it with `scripts/fetch-models.sh` (resumes, verifies SHA-256, refuses a
wrong file). The model is never committed: `*.gguf` is git-ignored and
`models/` holds it.

## Setup per platform

### Android (arm64 phone)

1. `brew install cmake`, install the NDK (see table above), enable USB debugging.
2. `scripts/fetch-models.sh --push`. It runs
   `adb push` to `/sdcard/Android/data/<applicationId>/files/models/`, the app's
   external files directory. That works for debug, profile and release builds;
   the private files directory would need `run-as`, which profile builds refuse.
   The id is read from `app/android/app/build.gradle*`; override with `APP_ID=`.
3. The app finds the model with `path_provider`
   `getExternalStorageDirectory()` + `/models/<file>`. Reading a large file
   through `/sdcard` is slower than app-private storage; the adapter may copy it
   once to `getApplicationSupportDirectory()` and load from there.
4. `flutter run --profile -d <phone>`. The first build compiles llama.cpp for
   `android-arm64` (the hook runs once per ABI Flutter builds, which is just the
   phone's for `flutter run`).
5. Set `minSdk` to 28 or higher (Flutter's default is lower; the hook compiles
   against API 28, as llama.cpp's own Android recipe does).

### iPhone

1. Xcode installed, a signing team set once in the Runner target (already needed
   for any device build). iPhone on iOS 16.4 or newer (llama.cpp's own iOS
   floor). Recommended: set the app's deployment target to 16.4 so the declared
   minimum matches.
2. **Recommended route for the model: Finder file sharing.** No network, no
   server, repeatable on stage. The app's `Info.plist` needs
   `UIFileSharingEnabled = YES` and `LSSupportsOpeningDocumentsInPlace = YES`
   (the app owner adds these two keys). Then: plug the phone in, open Finder,
   select the iPhone, Files tab, drag `models/qwen2.5-0.5b-instruct-q4_k_m.gguf`
   onto the app. The app reads
   `getApplicationDocumentsDirectory()/models/<file>`, then `.../<file>`.
3. Alternative: let the app download on first launch from a URL the user sets
   (host the file on any HTTPS server, or on the Mac with
   `python3 -m http.server`). It needs Wi-Fi, a text field, a progress bar and
   the SHA-256 check in the app, so it is more code and more to go wrong
   on stage. Use it only if Finder file sharing is not an option.
4. `flutter run --profile -d <iPhone>`. The first build compiles llama.cpp for
   `ios-arm64`; the iOS simulator works too (CPU), but numbers from it mean
   nothing.

### Build settings (optional, in the app's `pubspec.yaml`)

```yaml
hooks:
  user_defines:
    llm_bridge:
      arm_arch: armv8.2-a+dotprod+fp16   # default; use armv8-a for very old CPUs,
                                         # or armv8.6-a+i8mm+dotprod+fp16 for newer ones
      jobs: 6                            # parallel compile jobs (default: cores, 1 per 1.5 GB RAM)
      cmake: /opt/homebrew/bin/cmake     # if cmake is not on the PATH Flutter sees
      llama_cpp_dir: /path/to/llama.cpp  # use a local checkout of tag b11610 (offline)
```

Hooks run with a filtered environment (only `PATH`, `HOME`, `ANDROID_HOME`,
`ANDROID_NDK*` and proxy variables), so these keys, not environment variables,
are the way to configure the build. For offline builds, a checkout of
`b11610` placed at `packages/llm_bridge/third_party/llama.cpp` (git-ignored) is
used automatically. `flutter run -v` shows the hook's progress; the full CMake
log is `build.log` inside `.dart_tool/hooks_runner/shared/llm_bridge/build/`.

### Moving to a newer llama.cpp

Change `llamaCppTag` and `llamaCppCommit` in `hook/build.dart` (one commit id
from `git ls-remote https://github.com/ggml-org/llama.cpp refs/tags/bNNNN`),
run `dart test`, then the smoke test below. The C wrapper uses only the stable
core API (`llama_model_load_from_file`, `llama_init_from_model`,
`llama_decode`, samplers, `llama_chat_apply_template`); renamed functions fail
at compile time, not at run time.

## What was verified, and where

Verified in the Linux arm64 VM (Dart 3.13.5, llama.cpp b11610 built by the real
hook with CMake and gcc, CPU only):

- `flutter analyze` clean; `dart format` clean.
- 30 unit tests (no model needed), most with a fake native layer: chat-template fallback and message
  assembly, lazy start, ordered streaming, `maxTokens`, stats, native error as
  stream error, `cancel()`, cancelling the subscription, restart cancels the
  old run, three queued runs, dispose while streaming.
- 7 smoke tests with the real model: streaming, repeatable greedy output, the
  model's own template equals our ChatML fallback for Qwen2.5, cancel under
  2 s, a too-long prompt is a stream error, no U+FFFD in emoji output.
- The portable Android-style flags (`GGML_NATIVE=OFF`, `GGML_LLAMAFILE=OFF`,
  `armv8.2-a+dotprod+fp16`) compile and link on Linux arm64.
- The git commands of the fetch step (partial clone + sparse checkout + HEAD
  check) against a local repository.
- Download URL and SHA-256 of the model against Hugging Face's published value.

Real generation, **Linux VM (shared, 4 vCPU), not a phone**, Qwen2.5-0.5B
Q4_K_M, 4 threads, greedy, `example/generate.dart`:

| Run | Prompt tokens | Generated | Time to first token | Decode (Dart) | Decode (native) |
| --- | --- | --- | --- | --- | --- |
| "Explain what dart:ffi is" | 30 | 65 | 194 ms | 82.2 tok/s | 82.1 tok/s |
| "List five fruits." | 23 | 26 | 156 ms | 74.4 tok/s | 74.2 tok/s |
| smoke test, 10 tokens | 23 | 10 | 157-178 ms | 55-68 tok/s | 55-67 tok/s |

A 4 ms Dart timer running next to the model fired with a worst gap of 8 to 9 ms
(VM jitter): the isolate stays free. The bridge adds under 1 percent to the
decode rate. Phone numbers will be much lower; do not quote these.

Only the Mac and the phones can verify:

- The hook on Android: NDK discovery, `android.toolchain.cmake`, `c++_static`,
  16 KB page alignment, the Gradle packaging of the library.
- The hook on iOS: `CMAKE_SYSTEM_NAME=iOS` with Makefile/Ninja generators,
  Accelerate/BLAS, the `-Wl,-encryptable` link flag, Flutter turning the dylib
  into a framework and signing it, device vs simulator SDK selection.
- The git fetch against github.com (the VM could not reach it; the VM used the
  local-checkout route).
- Speed, memory, thermal behaviour and `-march` compatibility on real phones.
- That Android 13+ still accepts `adb push` into `Android/data`.

## Known risks

- **First build time.** About two minutes on a 4-core Linux VM for one ABI;
  expect 1 to 4 minutes per ABI on a Mac. Later builds are cached. A change to
  `src/` or `hook/` rebuilds.
- **CMake on the Mac** is a prerequisite the other options do not have.
- **The iOS and Android paths are unexecuted** (list above). The hook prints the
  exact CMake command and keeps `build.log`; failures should be readable.
- **CPU only.** Metal (iOS) and Vulkan (Android) are off on purpose: same code
  path on both phones, no shader or driver issues. The rate will be lower than
  GPU-backed apps on the newest phones; say so on stage.
- **CPU baseline.** `armv8.2-a+dotprod+fp16` needs a phone from about 2019 on
  (Cortex-A55/A76 class, Apple A13 and newer). Older iPhones (XS, XR, 8, X)
  would crash with an illegal instruction; set `arm_arch: armv8-a` for them.
- **Threads.** `threads: 4` is a good default on 4+4 and 1+3+4 phones; more
  threads can be slower when they land on efficiency cores.
- **Memory.** About 600 MB resident for this model and a 1024-token context. A
  larger `contextSize` grows the KV cache linearly.
- **Hook environment.** Flutter started from an IDE launched from the Dock may
  not have Homebrew on `PATH`. The hook also looks in `/opt/homebrew/bin`,
  `/usr/local/bin` and the Android SDK for `cmake` and `ninja`.
- **Token strings are heap copies.** If the isolate is torn down with events
  still queued, those few small strings leak. Normal use (`dispose()`) does not.
- **One generation at a time per model**, by design (one KV cache).
- **llama.cpp moves fast.** The pin is the protection. Bumping it is a
  one-line change plus a test run, but do it before the talk, not on the day.
