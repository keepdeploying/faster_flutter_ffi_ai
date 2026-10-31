# channel_bridge

The platform-channel half of the "Faster Flutter" demo. It moves bytes between
Dart and Kotlin/Swift, and runs the same MobileNet classifier behind a channel,
so the FFI path has something fair to be measured against.

The package has no dependency on the app. It exposes plain Dart types; the app
wraps them in its own `PayloadBridge` and `Classifier` adapters.

```dart
import 'package:channel_bridge/channel_bridge.dart';

final bridge = ChannelPayloadBridge(ChannelKind.binary);
await bridge.warmUp(65536);
final sum = await bridge.roundTrip(payload); // byte sum modulo 2^32, by ffb_checksum in C
bridge.dispose();

final classifier = ChannelClassifier();
await classifier.load(
  modelAssetKey: 'assets/models/mobilenet_v1_1.0_224.tflite',
  labelsAssetKey: 'assets/models/labels.txt',
);
final r = await classifier.classify(rgba, 640, 480); // ChannelSite.platformThread for the jank demo
// r.index, r.label, r.confidence, r.preprocessMicros, r.inferenceMicros (native clock), r.totalMicros (Dart clock)
```

## The two channel setups

| | `ChannelKind.method` | `ChannelKind.binary` |
| --- | --- | --- |
| Channel | `MethodChannel('faster_flutter/method')` | `BasicMessageChannel<ByteData?>('faster_flutter/binary')` |
| Codec | `StandardMethodCodec` / `StandardMessageCodec` | `BinaryCodec` (Android handler: `BinaryCodec.INSTANCE_DIRECT`; iOS: `FlutterBinaryCodec`) |
| Call | `roundTrip(Uint8List) -> int` | payload in, 4-byte little-endian checksum out |
| Dart side | writes the call and the bytes into a message buffer | sends a `ByteData` view of the same bytes, no encoding |
| Native side | decodes the call, copies the bytes into a `ByteArray` (Kotlin) or `FlutterStandardTypedData` (Swift), looks the method up by name, encodes the reply | Android: a direct `ByteBuffer` over the engine's memory, no decode, no copy. iOS: the `NSData` as is |
| Threads | Dart (UI thread) to the platform thread and back | the same two threads |

Both setups cross the same two threads: the message goes from the UI thread,
where Dart runs, to the platform's main thread, and the reply returns to the UI
thread. What differs is the work around the hop. The Flutter team found that
encoding and decoding cost more than the copy itself, and that
`BinaryCodec.INSTANCE_DIRECT` on Android and `FlutterBinaryCodec` on iOS give
the fastest `BasicMessageChannel` (about 42% faster on iOS and up to 52% faster
on Android for 1 MB messages, in their tests). See Aaron Clarke,
[Improving Platform Channel Performance in Flutter](https://flutter.dev/blog/improving-platform-channel-performance-in-flutter),
Flutter blog, 14 June 2021.

Neither setup is zero-copy. Each call copies the payload at least once, and
each blocks nothing on the Dart side but does queue work on the platform thread.
With merged threads (Flutter 3.29+ on mobile) the platform thread is also the
UI thread, so a slow handler costs frames. That is the point of the jank demo.

## The classifier

`faster_flutter/method` also carries two more methods:

| Method | Arguments | Reply |
| --- | --- | --- |
| `loadModel` | `{model: assetKey, labels: assetKey, threads: int}` | `null` |
| `classify` | `{rgba: Uint8List, width, height, site: "background" \| "platform"}` | `{index, label, confidence, preprocessUs, inferenceUs}` |

What a `classify` call crosses on Android:

1. Dart encodes the whole RGBA frame (copy 1) and hands it to the engine.
2. The platform thread decodes it into a `ByteArray` (copy 2).
3. `site: "background"` (default): the handler moves the work to a single
   background thread (a one-thread executor). That thread resizes the frame to
   224x224 (bilinear, RGB, floats in [-1, 1]) and runs the LiteRT interpreter,
   timing each with `System.nanoTime`. The reply is posted back to the platform
   thread, which sends a small map to Dart.
   `site: "platform"`: the same work runs inside the handler, on the platform
   thread, so the UI stops until it is done.
4. Dart measures the total with a `Stopwatch`. The bridge share is
   `total - preprocess - inference`.

The resize rule (half-pixel bilinear) is documented in `Preprocess.kt` and in
`app/assets/models/README.md`; the Dart and C preprocessors use the same rule.

`threads` (default 4) is the CPU thread count of the LiteRT interpreter. Give
the FFI classifier the same number.

## Platforms

- Android (Kotlin): everything above. LiteRT `com.google.ai.edge.litert:litert:1.4.2`,
  the version `flutter_litert` 3.9.4 uses for its Interpreter on Android. The
  Java API of that line is `org.tensorflow.lite.Interpreter`. `minSdk` 24.
- iOS (Swift, Swift Package Manager; the podspec is only the CocoaPods
  fallback): everything above, with the same behaviour as Android. `roundTrip`
  and the binary channel are unchanged. `loadModel` and `classify` run the same
  float MobileNet through the TensorFlow Lite C API. The resize is a port of
  `Preprocess.kt` (`Preprocess.swift`), `site: "platform"` runs in the handler on
  the main thread, any other site runs on a serial `DispatchQueue` and answers on
  the main thread, and both timings use `DispatchTime.now().uptimeNanoseconds`.
  iOS 15 or newer.

### iOS: where the TensorFlow Lite runtime comes from

The plugin has **no build-time dependency on any TensorFlow Lite binary**. At
`loadModel` time `TfLiteRuntime.swift` looks up the 20 C API functions it needs
with `dlsym(RTLD_DEFAULT, "TfLiteModelCreate")` and so on, and calls them through
`@convention(c)` function values. The functions are already in the process
because `flutter_litert` links `TensorFlowLiteC.framework`, and its
`flutter_litert_delegate_symbols.c` references every exported C function so the
linker cannot drop them. If they are not there, `loadModel` fails with
`FlutterError("runtime_missing")` and a message that names the missing symbols
and says to add `flutter_litert`.

Why this and not a second copy of the runtime:

- `flutter_litert` 3.9.4 itself finds the runtime this way. Its Dart side opens
  `DynamicLibrary.process()` on iOS (`lib/src/bindings/bindings.dart`), a lookup
  in the running process that its own podspec describes as
  `dlsym(RTLD_DEFAULT, ...)`. For frameworks loaded at launch, which this one is,
  our Swift lookup sees exactly the symbols Dart sees, and the channel and FFI
  classifiers run the same compiled runtime.
  That is what the demo needs: same model, same runtime, only the bridge differs.
- `flutter_litert` declares `TensorFlowLiteC` as a SwiftPM binary target (a large
  xcframework from its own GitHub release, `flex-v1.1.1`, checksum pinned in its
  `Package.swift`) and links it into its own dynamic product
  (`.library(name: "flutter-litert", type: .dynamic, ...)`), with anchors and
  linker settings so the symbols survive stripping (its CHANGELOG, 2.8.0 and
  2.8.2). Declaring the same binary target in this package would put a second
  `TensorFlowLiteC` framework of the same name into the same app, and a second
  copy of the C++ runtime into one process. Whether SwiftPM rejects the duplicate
  or links it and then misbehaves was not tried (there is no Xcode where this was
  written) and the sources below do not say. Either outcome is worse than no
  dependency, and the failure would show up on the stage laptop.
- The download URL and checksum belong to another project's release. A copy here
  would break the day they republish.
- Cost: this plugin only works in an app that also depends on `flutter_litert`.
  That is always true in this repository, and the error says so otherwise.

To use this plugin without `flutter_litert`, declare a TensorFlow Lite binary
target here instead. That is a separate change.

For a fair comparison the FFI classifier must use the same defaults as this
classifier: CPU, `threads` equal to the `threads` argument, and **no delegate**.
`flutter_litert`'s `InterpreterFactory` picks the Metal GPU delegate on iOS in
auto mode (`lib/src/interpreter_factory.dart`, `_createAutoMode`), so build the
interpreter with `Interpreter.fromAsset(..., options: InterpreterOptions()..threads = n)`
instead. This plugin adds no delegate. It uses whatever the packaged runtime
applies by default, which is also true of the Android `Interpreter`.

Sources: `flutter_litert` 3.9.4,
[source](https://github.com/hugocornellier/flutter_litert) and
[changelog](https://pub.dev/packages/flutter_litert/changelog) (files
`ios/flutter_litert/Package.swift`, `ios/flutter_litert.podspec`,
`lib/src/bindings/bindings.dart`, `src/tensorflow_lite/c_api.h` for the function
signatures); Dart,
[`DynamicLibrary.process`](https://api.dart.dev/stable/dart-ffi/DynamicLibrary/DynamicLibrary.process.html);
Apple, [`dlsym(3)`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/dlsym.3.html);
Flutter, [Swift Package Manager for plugin authors](https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-plugin-authors).

What is checked and how: see "Checking it" below. The Swift runtime layer was
type-checked and run on Linux against a stub of the C API, never against the real
iOS framework.

## Checking it

```sh
flutter analyze
flutter test        # Dart tests with mocked channels
```

The Kotlin and Swift code compiles only in a real Android or iOS build
(`scripts/bench-android.sh`, `scripts/bench-ios.sh`). `ChannelBridgePlugin.swift`
imports Flutter, so only that build checks it. `./gradlew testDebugUnitTest`
in an app's `android/` directory runs the small Kotlin tests for the resize. The
checksum tests skip there: `checksum()` calls `ffb_checksum` from
`libffi_bridge.so` through JNI, the same C function the FFI bridges call, and
that library only exists inside the app.

The Swift files that do not import Flutter (`Preprocess.swift`,
`TfLiteRuntime.swift`, `Classifier.swift`) also build on Linux. With a Swift
toolchain from swift.org and `gcc` on the path:

```sh
ios/linux_check/run.sh
```

It builds a small stand-in for the TFLite C API (`tflite_stub.c`, same exported
names and signatures as `c_api.h`), loads it with `RTLD_GLOBAL` so that
`dlsym(RTLD_DEFAULT, ...)` finds it as it finds `flutter_litert`'s framework on
iOS, and checks: the known-pixel cases of `NativeMathTest.kt`, the resize against
an independent `Double` implementation, the labels parser, the error messages, the
whole load and classify path with the real `mobilenet_v1_1.0_224.tflite`, and that
every C object is freed. The stub's "inference" is not MobileNet, so it says
nothing about accuracy or speed on a phone.
