# Architecture

This repository is the demo and the measurement harness for the talk
"Faster Flutter: Accessing On-Device AI with Dart FFI" (Obumuneme Nwabude, GDE
Cloud AI & Dart-Flutter). Every number on a results slide comes from a file this
repository writes. Nothing is typed in by hand.

The one rule behind every design choice: **same model, same input, same phone;
only the bridge differs.**

## Layout

```text
faster_flutter_ffi/
  .fvmrc                    Flutter 3.47.6, the version every step is checked with
  README.md                 what the demo shows, the results, how to reproduce them
  app/                      the Flutter app (only Dart code and assets are committed)
    lib/main.dart
    lib/bridges/            bridge.dart = the contracts; one file per implementation
    lib/bench/              runner, stats, frame-time meter, results JSON
    lib/screens/            home, bridge race, classify, generate, benchmark
    lib/theme/              tokens, theme, fonts, icons
    assets/models/          float MobileNet V1 1.0/224 .tflite + labels (17 MB, committed)
    assets/frames/          fixed test frames (committed, so runs repeat)
    assets/fonts/, assets/icon/
    integration_test/       the full benchmark, `flutter drive --profile`
    test/                   unit and widget tests, fake bridges only
  packages/
    ffi_bridge/             package_ffi: C sources, hook/build.dart, ffigen bindings
    channel_bridge/         Flutter plugin: Kotlin (Android) and Swift (iOS) handlers
    llm_bridge/             llama.cpp over FFI: build hook, C wrapper, token stream
  tool/                     faster_flutter_tool: bin/report.dart turns a results JSON
                            into Markdown tables + SVG charts (own tests, plain Dart)
  scripts/                  setup.sh, fetch-models.sh, bench-android.sh, bench-ios.sh,
                            report-latest.sh, check-all.sh, lib.sh (shared helpers)
  results/                  curated runs: <yyyy-mm-dd>_<device>.json (+ generated report)
```

The app depends on both packages by `path:`. No pub workspace: the
flutter-demo-kit scripts look for one Flutter app at the root or one level down,
and a root workspace pubspec would confuse them.

## Contracts

`app/lib/bridges/bridge.dart` is the source of truth. Do not change a signature
without updating every implementation and test in the same change.

| Interface | Implementations | Lives in |
| --- | --- | --- |
| `PayloadBridge` | methodChannel, binaryChannel | `channel_bridge` (Dart side + Kotlin + Swift) |
| `PayloadBridge` | ffiCopy, ffiLeaf, ffiZeroCopy | `ffi_bridge` |
| `Preprocessor` | Dart, C (via FFI) | app (Dart), `ffi_bridge` (C) |
| `Classifier` | channel (Kotlin runs LiteRT 1.4.2 on Android) | `channel_bridge` |
| `Classifier` | FFI (`flutter_litert` 3.9.4, LiteRT 1.4.2 on Android) | app/lib/bridges or `ffi_bridge` |
| `TokenGenerator` | C demo generator on a pthread + `NativeCallable.listener` | `ffi_bridge` |
| `TokenGenerator` | real LLM: Qwen2.5-0.5B-Instruct Q4_K_M through llama.cpp over FFI | `llm_bridge` (`LlamaTokenGenerator`, app adapter in `app/lib/bridges/`) |

Packages must not import the app. Each package exposes a small public API
(classes named `ChannelPayloadBridge`, `FfiPayloadBridge(kind)`,
`NativePreprocessor`, `ChannelClassifier`, `DemoTokenGenerator`, ...) that
implements interfaces it receives as plain Dart types, or the app wraps them in a
thin adapter in `app/lib/bridges/`. Prefer the adapter: packages stay independent.

`ffi_bridge` is built by a build hook (`hook/build.dart`) that uses
`native_toolchain_c` ^0.19.5 and `code_assets` ^2.1.0: no CMake, podspec or
Gradle file. `llm_bridge` has its own hook that runs CMake on a pinned llama.cpp
commit (docs/LLM.md).

**One preprocessing rule.** Every preprocessor (Kotlin, Dart, C) does the same
thing, so the only thing that differs between runs is the bridge: a half-pixel
bilinear resize from the RGBA frame to 224 x 224, with
`src = (dst + 0.5) * scale - 0.5` on each axis, clamped to the frame; alpha
dropped; RGB floats in [-1, 1] (`pixel / 127.5 - 1`).

### Native side, C (`ffi_bridge/src/ffi_bridge.h`)

```c
uint32_t ffb_checksum(const uint8_t* data, size_t len);          // leaf-safe
uint8_t* ffb_alloc(size_t len);  void ffb_free(uint8_t* p);
void ffb_preprocess_rgba(const uint8_t* rgba, int32_t w, int32_t h,
                         float* out, int32_t size);              // half-pixel bilinear, clamped, [-1, 1]
// Demo token stream: starts a pthread that calls `on_token` once per token,
// sleeping `delay_ms` between tokens, then calls it with NULL to signal the end.
int64_t ffb_demo_generate(const char* prompt, int32_t max_tokens, int32_t delay_ms,
                          void (*on_token)(int64_t stream_id, const char* token));
void ffb_demo_cancel(int64_t stream_id);
```

Checksum = byte sum modulo 2^32, identical to `checksum()` in Dart, Kotlin and
Swift. Every round trip asserts it.

### Channel names

- `faster_flutter/method` (MethodChannel, StandardMessageCodec): methods
  `roundTrip(Uint8List) -> int`, `loadModel({model, labels, threads}) -> null`
  (`model` and `labels` are asset keys, `threads` is the LiteRT thread count),
  `classify({rgba, width, height}) -> {index, label, confidence, preprocessUs, inferenceUs}`.
- `faster_flutter/binary` (BasicMessageChannel, BinaryCodec): payload in, 4-byte
  little-endian checksum out. Android uses `BinaryCodec.INSTANCE_DIRECT`.

Native timings use the monotonic clock on each side (`System.nanoTime`,
`DispatchTime`), measured inside the handler.

## Models

- **Classifier:** MobileNet V1, width 1.0, 224 x 224, float32 (not quantized),
  Apache-2.0. One file for every classifier in the demo. Source, checksums and
  labels: `app/assets/models/README.md`. On Android both paths run it on
  LiteRT 1.4.2: the Kotlin handler in `channel_bridge`
  (`com.google.ai.edge.litert:litert:1.4.2`) and `flutter_litert` 3.9.4 over FFI.
- **LLM:** Qwen2.5-0.5B-Instruct, Q4_K_M, Apache-2.0, through
  `packages/llm_bridge` (llama.cpp tag b11610, CPU only). Never committed:
  `scripts/fetch-models.sh` downloads it and checks its SHA-256. Why this model,
  and how it gets onto each phone: docs/LLM.md.

## Results file (schema 1)

```json
{
  "schema": 1,
  "createdAt": "2026-10-14T10:00:00Z",
  "device": {"platform": "android", "model": "Pixel 8", "os": "16", "abi": "android_arm64"},
  "flutter": "3.47.6",
  "buildMode": "profile",
  "suites": [
    {"suite": "round_trip", "bridge": "ffiLeaf", "payloadBytes": 1024,
     "warmup": 200, "runs": 2000,
     "stats": {"p50Us": 0.4, "p95Us": 0.6, "p99Us": 1.1, "meanUs": 0.5, "minUs": 0.3, "maxUs": 12.0}},
    {"suite": "preprocess", "impl": "c", "runs": 500, "stats": {}},
    {"suite": "classify", "bridge": "ffiCopy", "site": "isolate", "runs": 300,
     "total": {}, "preprocess": {}, "inference": {}, "overhead": {}},
    {"suite": "jank", "bridge": "methodChannel", "site": "uiThread", "seconds": 30,
     "frames": 1800, "jankyFrames": 42, "worstFrameMs": 61.2, "budgetMs": 16.7},
    {"suite": "generate", "generator": "demo", "tokens": 128,
     "firstTokenMs": 3.1, "tokensPerSec": 40.0, "jankyFrames": 0}
  ]
}
```

`device.abi` is `Abi.current().toString()` from `dart:ffi` (`android_arm64`,
`ios_arm64`). `flutter` comes from `--dart-define=FFB_FLUTTER_VERSION=...` (the
plain `FLUTTER_VERSION` is reserved by the framework); the bench scripts pass
the version they detect, and the default is 3.47.6. In a
`classify` suite the stats object is named `overhead`, not `bridge` (the name
`bridge` already holds the bridge's own name): it is the time that is neither
preprocessing nor inference, which is the bridge.

Bridge names are `BridgeKind.name`. Times are microseconds as doubles. Payload
sizes for `round_trip`: 0, 1024, 65536, 602112 (224x224x3 float32), 8294400
(1920x1080 RGBA). A frame counts as janky when its total span from
`FrameTiming` exceeds the budget (16.7 ms at 60 Hz; use the display's refresh
rate when the engine reports it).

Rules for honest numbers: profile or release mode only (the app shows a banner
in debug mode and refuses to save results); warm up before measuring; report
percentiles, never only the mean; run each suite three times and keep the run
with the median p50; record the device and Flutter version in every file.

## UI and icons

The app is shown mirrored on a projector next to the slides, so it borrows the
deck's visual language and is readable from the back row.

**Subject.** A stage instrument, not a dashboard: its job is to make one
difference (the bridge) visible in a few seconds.

**The one memorable element: the pulse strip.** A full-width live strip at the
top of every demo screen that draws one thin vertical tick per frame, its height
the frame time, against a dashed 16.7 ms budget line. Ticks over budget are drawn
in the channel colour; the strip scrolls left. The jank counter sits at its right
end in large figures. Everything else on screen stays quiet.

**Colour** (from the GDE 2026 template, one meaning each, same as the slides):

| Token | Hex | Meaning |
| --- | --- | --- |
| ink | #20344B | text and lines (the template's navy) |
| paper | #FFFFFF | background; projectors wash out dark themes |
| channel | #EA4335 | anything on the platform-channel path, and over-budget frames |
| ffi | #34A853 | anything on the FFI path |
| accent | #4285F4 | neutral actions and focus |
| budget | #F9AB00 | the 16.7 ms budget line only |
| quiet | #20344B at 55% | secondary text, grid lines at 12% |

Halftone tints (#FF7DAF, #5CDB6D, #57CAFF, #FFD427) only as 16% fills behind the
matching strong colour. No gradients, no drop shadows, no generic grey cards.

**Type.** Google Sans Code (OFL, from Google Fonts, bundled as an asset so the app
works offline) for every number and every code identifier, with tabular figures,
since numbers are the content. One sans for everything else: Google Sans Flex if
its licence allows bundling, otherwise Roboto Flex. Scale: 15 / 20 / 28 / 44 /
72 sp; the hero number on a screen is 72. Sentence case everywhere, no all-caps
labels, no eyebrows above headings.

**Icons.** Material Symbols Rounded (the `material_symbols_icons` package, font
bundled), weight 400, one optical size. One icon per bridge kind, used everywhere
that bridge appears. App icon: an original mark (no Flutter or Dart logo): two
short horizontal strokes with a gap, crossed by one straight bolt that closes it,
ink on paper with the bolt in the FFI green. Ship it as `assets/icon/icon.svg`
plus a rendered 1024 px PNG, and configure `flutter_launcher_icons` (adaptive
icon on Android) so `scripts/setup.sh` generates the platform icons after
`flutter create`.

**Screens.**

1. Home: the talk title, then four rows (not cards), each a verb and what it
   shows: Race the bridges, Classify frames, Generate text, Run the benchmark.
2. Race the bridges: payload size chooser (the five sizes), a Run button, one
   horizontal bar per bridge on a log scale with p50 in Google Sans Code; bars
   grow live as samples arrive.
3. Classify frames: segmented control Channel | FFI (colour-coded), execution
   site control UI thread | Isolate | Native thread, the current frame with its
   top label and confidence, a stacked bar preprocess / bridge / inference, and
   the pulse strip. Frame source: bundled frames on a loop; live camera optional.
4. Generate text: model control Demo generator | LLM, prompt field, streaming
   output in Google Sans Code, first-token time and tokens per second, pulse strip
   underneath to prove the UI keeps its frames.
5. Run the benchmark: one button, progress per suite, a results table, Save and
   Share. Saving writes `results/<date>_<model>.json` in app documents and prints
   one line `FFB_RESULTS_PATH=<path>` that the bench scripts look for.

Motion: only what answers an action, plus the pulse strip itself. Respect
`MediaQuery.disableAnimations`. Every control has a semantics label; contrast
of text on paper is at least 4.5:1.

## Steps (Git tags)

`main` always holds the finished app. The tags mark the stages of the talk, each a
working app on one straight line, as in workshop-repo-template:

| Tag | What the step adds |
| --- | --- |
| step-01 | App shell, theme, pulse strip, channel round trip (both channel kinds) |
| step-02 | `ffi_bridge` package: C checksum through FFI with a copy |
| step-03 | Leaf calls and zero-copy buffers; the bridge race screen complete |
| step-04 | The classifier on both paths, C preprocessing |
| step-05 | Off the UI thread: isolate and native thread; jank comparison |
| step-06 | Token streaming: C demo generator, then the real LLM |
| final | Benchmark screen, integration test, report tool, README results |

Tags are created by the maintainer only after `check-steps.sh` passes.

Git note: agents commit nothing.

## Code style

- Comments explain why, in the talk's words, as in scrolling_flutter_vs_css:
  each bridge file says what happens underneath and what the other path does.
- `flutter_lints`, zero analyzer warnings, `dart format`.
- No new dependency without a one-line reason in the pubspec comment.
- Write plain English in docs: short sentences, no hype.

## Checking work

Agents work in a Linux VM that has this folder mounted and Flutter 3.47.6 for
Linux at `$HOME/tools/flutter/bin`. In that VM:

- `scripts/check-all.sh` runs all of the following, plus the report tool's
  tests and a syntax check of the scripts.
- `flutter analyze` and `flutter test` for the app and each package.
- `dart test` in `packages/ffi_bridge` runs the C code for real (Linux build
  through the build hook).
- Android and iOS builds, and anything on a phone, run on the Mac itself, through
  `scripts/bench-android.sh` and `scripts/bench-ios.sh`. Kotlin and Swift code is
  checked by those builds, so keep it small and plain.
