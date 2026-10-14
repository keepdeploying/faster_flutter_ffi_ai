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
final sum = await bridge.roundTrip(payload); // byte sum modulo 2^32, from Kotlin or Swift
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
  fallback): `roundTrip` and the binary channel are implemented. `loadModel` and
  `classify` answer `FlutterError("unsupported_on_ios")`. The TODO in
  `ChannelBridgePlugin.swift` says what is missing: the TensorFlow Lite C runtime
  cannot simply be added to this package while the app also links
  `flutter_litert`, which ships it.

## Checking it

```sh
flutter analyze
flutter test        # Dart tests with mocked channels
```

The Kotlin and Swift code compiles only in a real Android or iOS build
(`scripts/bench-android.sh`, `scripts/bench-ios.sh`). `./gradlew testDebugUnitTest`
in an app's `android/` directory runs the small Kotlin tests for the checksum and
the resize.
