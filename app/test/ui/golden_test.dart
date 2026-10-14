// Screenshot tests: each screen at 412 x 915 logical px (a Pixel 8), with the
// real bundled fonts and icons. Regenerate with
//   flutter test test/ui --update-goldens
// then look at test/ui/goldens/*.png. Time is faked, so the images repeat.

import 'package:faster_flutter/bridges/bridge.dart';
import 'package:faster_flutter/screens/benchmark_screen.dart';
import 'package:faster_flutter/screens/classify_screen.dart';
import 'package:faster_flutter/screens/generate_screen.dart';
import 'package:faster_flutter/screens/home_screen.dart';
import 'package:faster_flutter/screens/race_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ui_harness.dart';

void main() {
  setUpAll(loadRealFonts);

  Future<void> shot(WidgetTester tester, String name) async {
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/$name.png'),
    );
  }

  testWidgets('home', (tester) async {
    usePhone(tester);
    final s = TestServices(jank: 5);
    await tester.pumpWidget(s.app(const HomeScreen()));
    await tester.pump(const Duration(milliseconds: 100));
    await shot(tester, 'home');
  });

  testWidgets('race idle', (tester) async {
    usePhone(tester);
    final s = TestServices(jank: 5);
    await tester.pumpWidget(s.app(const RaceScreen()));
    await tester.pump(const Duration(milliseconds: 100));
    await shot(tester, 'race_idle');
  });

  testWidgets('race in a debug build', (tester) async {
    usePhone(tester);
    final s = TestServices(jank: 5, debugBuild: true);
    await tester.pumpWidget(s.app(const RaceScreen()));
    await tester.pump(const Duration(milliseconds: 100));
    await shot(tester, 'race_debug');
  });

  testWidgets('race running', (tester) async {
    usePhone(tester);
    final s = TestServices(jank: 5);
    await tester.pumpWidget(s.app(const RaceScreen()));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byType(FilledButton));
    // Stop part-way: a few batches in, every bar has a value.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.text('Stop'), findsOneWidget);
    await shot(tester, 'race_running');
    // Let the race finish so no timers are left.
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  });

  group('classify', () {
    Future<List<Frame>> cats() async => [
      await loadFrameAsset('assets/frames/tabby_cat.jpg'),
    ];

    testWidgets('channel with janky frames', (tester) async {
      usePhone(tester);
      final frames = (await tester.runAsync(cats))!;
      final s = TestServices(jank: 6, frames: frames);
      await tester.pumpWidget(s.app(const ClassifyScreen()));
      await tester.pump(const Duration(milliseconds: 250));
      await letImagesDecode(tester);
      await shot(tester, 'classify_channel');
    });

    testWidgets('ffi with a clean strip', (tester) async {
      usePhone(tester);
      final frames = (await tester.runAsync(cats))!;
      final s = TestServices(
        jank: 0,
        frames: frames,
        pulse: testPulse(janky: false),
      );
      await tester.pumpWidget(s.app(const ClassifyScreen()));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.text('FFI copy'));
      await tester.pump(const Duration(milliseconds: 250));
      await letImagesDecode(tester);
      await shot(tester, 'classify_ffi');
    });
  });

  testWidgets('generate mid-stream', (tester) async {
    usePhone(tester);
    final s = TestServices(jank: 0, pulse: testPulse(janky: false));
    await tester.pumpWidget(s.app(const GenerateScreen()));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byType(FilledButton));
    // 90 ms to the first token, then one word every 40 ms.
    await tester.pump(const Duration(milliseconds: 90));
    for (var i = 0; i < 24; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(find.text('Stop'), findsOneWidget);
    await shot(tester, 'generate');
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  });

  group('benchmark', () {
    testWidgets('idle', (tester) async {
      usePhone(tester);
      final s = TestServices(jank: 5);
      await tester.pumpWidget(s.app(const BenchmarkScreen()));
      await tester.pump(const Duration(milliseconds: 100));
      await shot(tester, 'benchmark_idle');
    });

    testWidgets('finished', (tester) async {
      usePhone(tester);
      final s = TestServices(jank: 5);
      await tester.pumpWidget(s.app(const BenchmarkScreen()));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byType(FilledButton));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await shot(tester, 'benchmark_done');
    });
  });
}
