// The full benchmark on a real phone, in profile mode:
//
//   cd app
//   flutter drive --profile --driver=test_driver/perf_driver.dart \
//     --target=integration_test/bench_test.dart -d <device-id>
//
// Add --dart-define=QUICK=true for a one-minute run that only checks the
// wiring. scripts/bench-android.sh and scripts/bench-ios.sh do all of this.
//
// The results travel back to the Mac through the integration_test report, and
// test_driver/perf_driver.dart writes them to results/raw/.

import 'package:faster_flutter/bench/frame_meter.dart';
import 'package:faster_flutter/bench/host.dart';
import 'package:faster_flutter/bridges/bridge.dart';
import 'package:faster_flutter/bridges/classifier_adapters.dart';
import 'package:faster_flutter/bridges/dart_preprocessor.dart';
import 'package:faster_flutter/bridges/generator_adapters.dart';
import 'package:faster_flutter/bridges/native_preprocessor_adapter.dart';
import 'package:faster_flutter/bridges/payload_adapters.dart';
import 'package:faster_flutter/main.dart';
import 'package:faster_flutter/services/frame_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const quick = bool.fromEnvironment('QUICK');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Real frames at the display's rate, so the jank suite measures what a user
  // would see, not frames the test pumps by hand.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('full benchmark', (tester) async {
    // The app's home screen draws something on every frame, as on stage.
    await tester.pumpWidget(const FasterFlutterApp());
    await tester.pump();

    final meter = FrameMeter()..start(keepFramesFlowing: true);
    final bridges = createPayloadBridges();
    final native = NativePreprocessorAdapter();
    final generators = <TokenGenerator>[
      DemoGeneratorAdapter(),
      LlamaGeneratorAdapter(),
    ];
    final host = RealBenchmark(
      payloadBridges: bridges,
      preprocessors: [const DartPreprocessor(), native],
      classifierAt: classifierAt,
      generators: generators,
      frames: () async => (await BundledFrames.load()).frames,
      meter: meter,
      config: quick ? BenchConfig.quick : BenchConfig.full,
    );

    try {
      await tester.runAsync(() async {
        await for (final p in host.run()) {
          if (p.done) {
            // ignore: avoid_print
            print('FFB_SUITE_DONE ${p.suite}: ${p.rows.length} rows');
          }
        }
      });
      final results = host.results!;
      expect(results.suites, isNotEmpty);
      binding.reportData = <String, Object?>{
        'fileName': results.fileName,
        'results': results.toJson(),
      };
    } finally {
      host.dispose();
      meter.dispose();
      for (final b in bridges) {
        b.dispose();
      }
      native.dispose();
      for (final g in generators) {
        g.dispose();
      }
    }
  }, timeout: const Timeout(Duration(minutes: 45)));
}
