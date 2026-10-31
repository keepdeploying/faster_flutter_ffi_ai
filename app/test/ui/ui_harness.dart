// Shared set-up for the screenshot tests: real fonts, a phone-sized view,
// deterministic services, and a helper that wraps a screen the way main.dart
// does. Only test code lives here.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:faster_flutter/app_services.dart';
import 'package:faster_flutter/bridges/bridge.dart';
import 'package:faster_flutter/screens/preview_services.dart';
import 'package:faster_flutter/theme/theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pixel 8-ish: 412 x 915 logical px at 2.625.
const phoneSize = Size(412, 915);
const phoneRatio = 2.625;

/// Reads the bundled TTFs so goldens show the real type and icons, not Ahem.
Future<void> loadRealFonts() async {
  Future<void> load(String family, Uint8List bytes) async {
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
  }

  await load(
    'GoogleSansFlex',
    File('assets/fonts/GoogleSansFlex.ttf').readAsBytesSync(),
  );
  await load(
    'GoogleSansCode',
    File('assets/fonts/GoogleSansCode.ttf').readAsBytesSync(),
  );
  // Isolate.resolvePackageUri is not supported under flutter test, so read the
  // package config the tool wrote.
  final config = File('.dart_tool/package_config.json');
  final packages = (jsonDecode(config.readAsStringSync()) as Map)['packages'];
  final root =
      (packages as List).cast<Map>().firstWhere(
            (p) => p['name'] == 'material_symbols_icons',
          )['rootUri']
          as String;
  final base = config.absolute.uri.resolve(
    root.endsWith('/') ? root : '$root/',
  );
  final fontFile = File.fromUri(
    base.resolve('lib/fonts/MaterialSymbolsRounded.ttf'),
  );
  await load(
    'packages/material_symbols_icons/MaterialSymbolsRounded',
    fontFile.readAsBytesSync(),
  );
}

/// Sets the view to a phone with a status bar and a gesture bar.
void usePhone(WidgetTester tester) {
  tester.view.devicePixelRatio = phoneRatio;
  tester.view.physicalSize = Size(
    phoneSize.width * phoneRatio,
    phoneSize.height * phoneRatio,
  );
  const top = 28.0 * phoneRatio;
  const bottom = 20.0 * phoneRatio;
  tester.view.padding = const FakeViewPadding(top: top, bottom: bottom);
  tester.view.viewPadding = const FakeViewPadding(top: top, bottom: bottom);
  addTearDown(tester.view.reset);
}

/// A readable pulse: steady frames with hitches inside the visible window.
/// [janky] false gives a clean run.
FrameTimeBuffer testPulse({bool janky = true, int count = 120}) {
  final b = FrameTimeBuffer(capacity: 240);
  for (var i = 0; i < count; i++) {
    // A smooth, slightly wavy 7 to 11 ms, no random numbers.
    var ms = 8.4 + 1.6 * _wave(i * 0.9) + 0.9 * _wave(i * 2.3 + 1);
    if (janky) {
      final fromEnd = count - 1 - i;
      if (fromEnd == 4) ms = 31;
      if (fromEnd == 5) ms = 22.5;
      if (fromEnd == 17) ms = 38;
      if (fromEnd == 29) ms = 19.5;
      if (fromEnd == 30) ms = 27;
      if (fromEnd == 41) ms = 21;
    }
    b.push(ms);
  }
  return b;
}

double _wave(double x) => math.sin(x);

/// Decodes a bundled JPEG into the RGBA [Frame] the classifier gets.
Future<Frame> loadFrameAsset(String path, {int width = 224}) async {
  final bytes = File(path).readAsBytesSync();
  final codec = await ui.instantiateImageCodec(bytes, targetWidth: width);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final f = Frame(
    rgba: data!.buffer.asUint8List(),
    width: image.width,
    height: image.height,
  );
  image.dispose();
  codec.dispose();
  return f;
}

/// A classifier that always answers the same, so the golden is the same.
class FixedClassifier implements Classifier {
  FixedClassifier(
    this.kind, {
    required this.label,
    required this.confidence,
    required this.preUs,
    required this.bridgeUs,
    required this.inferenceUs,
  });

  @override
  final BridgeKind kind;
  final String label;
  final double confidence;
  final int preUs;
  final int bridgeUs;
  final int inferenceUs;

  @override
  Future<void> load() async {}

  @override
  Future<Classification> classify(Frame frame) async => Classification(
    labelIndex: 0,
    label: label,
    confidence: confidence,
    totalMicros: preUs + bridgeUs + inferenceUs,
    preprocessMicros: preUs,
    inferenceMicros: inferenceUs,
  );

  @override
  void dispose() {}
}

/// Streams the preview text word by word with fake-time delays, advancing the
/// manual clock the same amount, so speed and first-token time repeat exactly.
class SteppedGenerator implements TokenGenerator {
  SteppedGenerator(
    this.clock, {
    required this.label,
    required this.isRealModel,
  });

  final ManualClock clock;
  @override
  final String label;
  @override
  final bool isRealModel;

  static const _text =
      'A channel encodes the call, copies the bytes and hops threads, and '
      'every one of those steps shows up in the frame time. FFI passes a '
      'pointer and stays where it started, so the UI keeps its frames while '
      'the tokens stream in.';

  @override
  Future<void> load() async {}

  @override
  Stream<String> generate(String prompt, {int maxTokens = 128}) async* {
    final words = _text.split(' ');
    await Future<void>.delayed(const Duration(milliseconds: 90));
    clock.advance(3100);
    for (var i = 0; i < words.length && i < maxTokens; i++) {
      if (i > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        clock.advance(40000);
      }
      yield i == 0 ? words[i] : ' ${words[i]}';
    }
  }

  @override
  Future<void> cancel() async {}

  @override
  void dispose() {}
}

/// Wraps a preview bridge with a small fake-time delay per call, so a race
/// takes some (fake) time and a test can stop it part-way.
class SlowBridge implements PayloadBridge {
  SlowBridge(this.inner, this.delay);

  final PayloadBridge inner;
  final Duration delay;

  @override
  BridgeKind get kind => inner.kind;

  @override
  Future<void> warmUp(int maxBytes) => inner.warmUp(maxBytes);

  @override
  Future<int> roundTrip(Uint8List payload) async {
    await Future<void>.delayed(delay);
    return await inner.roundTrip(payload);
  }

  @override
  void dispose() => inner.dispose();
}

class TestServices {
  TestServices({
    this.frames,
    this.debugBuild = false,

    FrameTimeBuffer? pulse,
    int jank = 0,
    Duration frameInterval = const Duration(milliseconds: 100),
  }) : clock = ManualClock(),
       pulse = pulse ?? testPulse(),
       jank = ValueNotifier<int>(jank),
       interval = frameInterval;

  final ManualClock clock;
  final FrameTimeBuffer pulse;
  final ValueNotifier<int> jank;
  final List<Frame>? frames;
  final bool debugBuild;
  final Duration interval;

  Widget wrap(Widget screen) {
    final bridges = [
      for (final k in BridgeKind.values)
        SlowBridge(
          PreviewPayloadBridge(k, clock: clock),
          const Duration(microseconds: 300),
        ),
    ];
    return AppServices(
      payloadBridges: bridges,
      classifiers: {
        BridgeKind.methodChannel: FixedClassifier(
          BridgeKind.methodChannel,
          label: 'tabby cat',
          confidence: 0.91,
          preUs: 3100,
          bridgeUs: 1900,
          inferenceUs: 8200,
        ),
        BridgeKind.ffiCopy: FixedClassifier(
          BridgeKind.ffiCopy,
          label: 'tabby cat',
          confidence: 0.91,
          preUs: 880,
          bridgeUs: 140,
          inferenceUs: 8200,
        ),
      },
      classifierAt: (kind, site) => FixedClassifier(
        kind,
        label: 'tabby cat',
        confidence: 0.91,
        preUs: kind.isFfi ? 880 : 3100,
        bridgeUs: kind.isFfi ? 140 : 1900,
        inferenceUs: 8200,
      ),
      preprocessors: const [],
      generators: [
        SteppedGenerator(clock, label: 'Demo generator', isRealModel: false),
        SteppedGenerator(clock, label: 'LLM', isRealModel: true),
      ],
      frameTimes: pulse,
      jankCount: jank,
      jank: _TestJank(jank),
      frames: () {
        final f = frames ?? previewFramesForTest();
        return Stream<Frame>.periodic(interval, (i) => f[i % f.length]);
      },
      benchmark: PreviewBenchmark(stepDelay: Duration.zero),
      nowMicros: clock.call,
      debugBuild: debugBuild,
      child: screen,
    );
  }

  /// The app as main.dart builds it, with these services above the Navigator.
  Widget app(Widget home) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildTheme(),
    themeMode: ThemeMode.light,
    builder: (context, child) => wrap(child!),
    home: home,
  );
}

List<Frame> previewFramesForTest() => [
  Frame(rgba: Uint8List(4 * 4 * 4), width: 4, height: 4),
];

/// Minimal [JankMonitor] for the test harness. Rate mirrors the cumulative
/// jank counter, log and version stay inert. Enough for widget tests that
/// never read the log.
class _TestJank implements JankMonitor {
  _TestJank(this._cumulative);

  final ValueListenable<int> _cumulative;

  @override
  ValueListenable<int> get jankPerSecond => _cumulative;

  @override
  ValueListenable<int> get jankLogVersion => _version;
  final ValueNotifier<int> _version = ValueNotifier<int>(0);

  @override
  double get budgetMs => 16.7;

  @override
  List<JankEntry> get jankLog => const <JankEntry>[];

  @override
  void clearJankLog() {}
}

/// Pumps a few real-time moments so async image decoding can finish, then one
/// frame to draw the result.
Future<void> letImagesDecode(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 150)),
  );
  await tester.pump();
}
