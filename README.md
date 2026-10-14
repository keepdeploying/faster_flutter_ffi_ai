# Faster Flutter: Accessing On-Device AI with Dart FFI

This is the demo and the measurement harness for the talk "Faster Flutter: Accessing On-Device AI with Dart FFI". One Flutter app does the same three jobs on a real phone, once through platform channels and once through Dart FFI: move bytes to native code and back, classify a camera frame with MobileNet, and stream tokens from an on-device LLM. The rule behind everything: same model, same input, same phone, only the bridge differs. Every number on a results slide comes from a file this repository writes. Nothing is typed in by hand.

## The Five Bridges

| Bridge (`BridgeKind`) | What it is | What happens underneath |
| --- | --- | --- |
| `methodChannel` | `MethodChannel('faster_flutter/method')`, `StandardMessageCodec` | Dart encodes the call and the bytes. The platform thread (Kotlin or Swift) decodes them into a copy, looks the method up by name, runs it, and encodes the reply. |
| `binaryChannel` | `BasicMessageChannel` with `BinaryCodec` | No encoding: the bytes travel as they are. On Android the handler gets a direct `ByteBuffer`, so there is no decode and no copy on that side. |
| `ffiCopy` | A normal `dart:ffi` call | Dart copies the payload into a native buffer, then calls the C function. Cost grows with the payload. Safe for any native function. |
| `ffiLeaf` | `@Native(isLeaf: true)` | No copy and no VM transition: Dart passes the `Uint8List` itself. The C function must be short, must not block, and must never call back into Dart. |
| `ffiZeroCopy` | `dart:ffi` over native memory | The bytes already live in native memory. Dart fills a view once; each call then passes only a pointer and a length. |

Both channel kinds cross the same two threads (the UI thread and the platform thread). What differs is the work around the hop. Details: [packages/channel_bridge](packages/channel_bridge/README.md) and [packages/ffi_bridge](packages/ffi_bridge/README.md).

The app has four screens: race the bridges, classify frames, generate text, and run the benchmark. A strip at the top of each screen draws one tick per frame, so you can see jank as it happens.

## Results

The numbers come only from real phone runs, in profile mode. Not from an emulator, not from a simulator, not from a debug build. The app refuses to save a results file from a debug build.

This table is filled from [`results/`](results/README.md) after a run. Until then it shows a dash.

Round trip p50, 588 KB payload (a 224 x 224 float32 tensor):

| Bridge | Android phone | iPhone |
| --- | --- | --- |
| MethodChannel | - | - |
| BinaryCodec channel | - | - |
| FFI + copy | - | - |
| FFI leaf | - | - |
| FFI zero-copy | - | - |

One classify call and one generate run:

| | Android phone | iPhone |
| --- | --- | --- |
| Classify total p50, channel | - | - |
| Classify total p50, FFI | - | - |
| Janky frames in 30 s, channel on the UI thread | - | - |
| Janky frames in 30 s, FFI on an isolate | - | - |
| LLM tokens per second | - | - |

Each cell links to a report in `results/` when it is filled: `results/<date>_<phone>.md` has the full tables, and the folder next to it has the SVG charts for the slides. How the report is made: [results/README.md](results/README.md).

## Quick Start

```bash
git clone <this repository's URL>
cd faster_flutter_ffi
scripts/setup.sh
```

`scripts/setup.sh` checks your tools, generates the Android and iOS folders, makes the edits the LLM needs, gets the packages, and makes the app icons. It is safe to run twice. Only the Dart code, the C code and the assets are committed. The `android/` and `ios/` folders of the app are generated.

Then plug in a phone and run the app in profile mode:

```bash
cd app
flutter run --profile -d <phone id>
```

Profile mode runs at release speed and keeps DevTools. It does not run on emulators or simulators ([Flutter build modes](https://docs.flutter.dev/testing/build-modes)), and numbers from them mean nothing. For a look at the screens without a phone, VS Code has a "Preview with fakes" run configuration (`--dart-define=PREVIEW=true`). Its numbers are made up.

The first build compiles the C code and llama.cpp. It takes a few minutes. Later builds are fast.

Prefer VS Code? The repository has run configurations in `.vscode/launch.json` (Profile on a phone, Preview with fakes, Debug) and tasks in `.vscode/tasks.json`. Open the Terminal menu, pick Run Task, and choose Setup, Fetch models, Benchmark Android, Benchmark Android quick, Benchmark iOS, Make report from latest raw results, or Analyze and test everything.

## Run the Benchmark

Plug in one phone. With more than one, pass its id.

```bash
scripts/bench-android.sh            # a physical Android phone, USB debugging on
scripts/bench-ios.sh                # a physical iPhone, signing team set in Xcode
scripts/bench-android.sh --quick    # a short run, only to check that it works
scripts/bench-android.sh <device-id>
```

Each script does the same four things:

1. Checks that a physical phone is connected. Emulators and simulators are refused.
2. Runs `flutter drive --profile --driver=test_driver/perf_driver.dart --target=integration_test/bench_test.dart -d <id>`. It passes `--dart-define=FLUTTER_VERSION=<your version>`, and `QUICK=true` with `--quick`.
3. Checks that a new file landed in `results/raw/`.
4. Makes the report from it: `results/<name>.md` with the tables, and `results/<name>/` with four SVG charts (`round_trip`, `classify_split`, `jank`, `speedup`) at 1600 x 900, ready for a 16:9 slide.

Keep the phone unlocked, awake, on a charger and cool, with Do Not Disturb on. Each suite runs three times and the run with the median p50 is kept. To keep a run, copy the raw file next to its report and commit both:

```bash
cp results/raw/2026-10-14_pixel-8.json results/
```

To make the report again from the newest raw file, or from any file:

```bash
scripts/report-latest.sh
scripts/report-latest.sh results/2026-10-14_pixel-8.json
```

Or without the script, from the repository root:

```bash
dart run tool/bin/report.dart results/raw/<file>.json --out results/
```

Note: on an iPhone the channel classifier is not implemented yet (see [packages/channel_bridge](packages/channel_bridge/README.md)), so the channel classify rows are missing there. The report skips what a file does not have.

## The LLM Model

The "Generate text" screen can run a real model: Qwen2.5-0.5B-Instruct, Q4_K_M, 491 MB, through llama.cpp over FFI ([packages/llm_bridge](docs/LLM.md)). The model is never committed.

```bash
scripts/fetch-models.sh            # downloads into models/ and checks the SHA-256
scripts/fetch-models.sh --push     # also pushes it to a connected Android phone
```

On Android, `--push` runs `adb push` to `/sdcard/Android/data/<application id>/files/models/`, the app's external files folder. On an iPhone, use Finder file sharing: connect the phone, open Finder, select the iPhone, open the Files tab, and drag `models/qwen2.5-0.5b-instruct-q4_k_m.gguf` onto the app. `scripts/setup.sh` turns on `UIFileSharingEnabled` for this. Without the model, the screen still runs the C demo generator.

Why this model, what was checked and what was not, and the fallback: [docs/LLM.md](docs/LLM.md).

## What's Inside

- [`app/`](app): the Flutter app. Screens, the benchmark runner and the results model, and one adapter per bridge in `lib/bridges/`. Assets: the MobileNet model and labels, 11 test frames, fonts, the app icon. Tests use fake bridges only. `integration_test/` holds the full benchmark.
- [`packages/ffi_bridge/`](packages/ffi_bridge/README.md): the FFI side. A small C library, a build hook that compiles it (no CMake, podspec or Gradle file), and a thin Dart API.
- [`packages/channel_bridge/`](packages/channel_bridge/README.md): the platform-channel side. Dart, Kotlin and Swift, including the same classifier behind a channel.
- [`packages/llm_bridge/`](docs/LLM.md): llama.cpp over FFI. A build hook fetches one pinned commit and builds it with CMake; a native thread streams tokens to Dart with `NativeCallable.listener`.
- [`tool/`](tool): a small Dart command line tool. It turns a results file into Markdown tables and SVG charts, and has its own tests.
- [`scripts/`](scripts): `setup.sh`, `fetch-models.sh`, `bench-android.sh`, `bench-ios.sh`, `report-latest.sh`, `check-all.sh`.
- [`results/`](results/README.md): curated runs and their reports. `results/raw/` is scratch and not in Git.
- [`docs/`](docs): [ARCHITECTURE.md](docs/ARCHITECTURE.md) (layout, contracts, results format, rules for honest numbers) and [LLM.md](docs/LLM.md).

To check everything that does not need a phone (analyze, tests, the report tool, the scripts): `scripts/check-all.sh`.

## Requirements

- Flutter 3.47.6. It is pinned in `.fvmrc`; with [fvm](https://fvm.app) the scripts use it by themselves. Check with `flutter --version`.
- `cmake`, for the llama.cpp build: `brew install cmake`. `ninja` is optional and makes the build faster: `brew install ninja`.
- Android: the Android NDK (Android Studio, SDK Manager, SDK Tools, "NDK (Side by side)") and `adb`. A phone with Android 9 (API 28) or newer. `scripts/setup.sh` sets `minSdk` to 28.
- iOS: a Mac with Xcode, a signing team set once in `app/ios/Runner.xcworkspace`, and an iPhone on iOS 16.4 or newer. `scripts/setup.sh` sets the deployment target to 16.4.
- `git` and a network connection on the first build, which fetches llama.cpp.
- A physical phone. Profile mode does not run on emulators or simulators. The LLM build assumes a phone from about 2019 on (`armv8.2-a+dotprod+fp16`); for older ones see [docs/LLM.md](docs/LLM.md).

`scripts/setup.sh --check` checks these and changes nothing.

## Steps

`main` always holds the finished app. The tags mark the stages of the talk, each a working app on one straight line:

| Tag | What the step adds |
| --- | --- |
| `step-01` | App shell, theme, pulse strip, channel round trip (both channel kinds) |
| `step-02` | `ffi_bridge` package: C checksum through FFI with a copy |
| `step-03` | Leaf calls and zero-copy buffers; the bridge race screen complete |
| `step-04` | The classifier on both paths, C preprocessing |
| `step-05` | Off the UI thread: isolate and native thread; jank comparison |
| `step-06` | Token streaming: C demo generator, then the real LLM |
| `final` | Benchmark screen, integration test, report tool, README results |

To see exactly what a step changes, compare two tags. For example, what leaf calls and zero-copy add:

```bash
git diff step-02 step-03
```

If your code does not run and the room is moving on, save your work and jump ahead:

```bash
git stash push -u -m "my attempt"
git checkout step-04
```

## Sources

- Flutter: [Binding to native code using dart:ffi](https://docs.flutter.dev/platform-integration/bind-native-code).
- Dart: [Build hooks](https://dart.dev/tools/hooks) (the `hook/build.dart` files that compile the C code and llama.cpp) and [C interop using dart:ffi](https://dart.dev/interop/c-interop).
- `dart:ffi` API: [`Native`](https://api.dart.dev/dart-ffi/Native-class.html) (the `@Native` annotation and its `isLeaf` option) and [`NativeCallable`](https://api.dart.dev/dart-ffi/NativeCallable-class.html) (`NativeCallable.listener`, used for tokens).
- Threads: [Merged threads on macOS and Windows](https://docs.flutter.dev/release/breaking-changes/macos-windows-merged-threads) (it states that Android and iOS merged the platform and UI threads by default in Flutter 3.29) and [Merged threads on Linux](https://docs.flutter.dev/release/breaking-changes/linux-merged-threads). With merged threads, a slow platform-channel handler costs frames.
- Platform channel cost: Aaron Clarke, [Improving Platform Channel Performance in Flutter](https://flutter.dev/blog/improving-platform-channel-performance-in-flutter), 2021.
- Measuring: [Flutter build modes](https://docs.flutter.dev/testing/build-modes), [Flutter performance profiling](https://docs.flutter.dev/perf/ui-performance), [DevTools performance view](https://docs.flutter.dev/tools/devtools/performance) and [CPU profiler](https://docs.flutter.dev/tools/devtools/cpu-profiler).
- Models and runtimes: [MobileNet V1](https://github.com/tensorflow/models/blob/master/research/slim/nets/mobilenet_v1.md), [LiteRT](https://ai.google.dev/edge/litert), [llama.cpp](https://github.com/ggml-org/llama.cpp), [Qwen2.5-0.5B-Instruct GGUF](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF).

## Licence Notes

- The code in this repository: the licence is not chosen yet.
- **LLM model.** Qwen2.5-0.5B-Instruct is licensed under Apache-2.0, with no gate and no login. It is downloaded by `scripts/fetch-models.sh` and never committed. See the [model card](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF).
- **llama.cpp** is MIT licensed. The build hook fetches one pinned commit; nothing of it is committed here.
- **Classifier model.** MobileNet V1 (float, 224 x 224) is licensed under Apache-2.0. Source and checksums: [app/assets/models/README.md](app/assets/models/README.md). LiteRT is Apache-2.0.
- **Test frames.** The photos in `app/assets/frames/` come from Wikimedia Commons under CC0, public domain, or CC BY. CC BY needs a credit. All credits are in [app/assets/frames/CREDITS.md](app/assets/frames/CREDITS.md).
- **Fonts.** Google Sans Code and Google Sans Flex are licensed under the SIL Open Font License 1.1. The licence files are next to the fonts in `app/assets/fonts/`.
- Icons are Material Symbols Rounded (Apache-2.0), from the `material_symbols_icons` package. The app icon is an original mark.

## Slides

(Add the link to the slides here.)
