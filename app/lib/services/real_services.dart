// Builds AppServices from the real bridges: what runs on a phone in profile
// and release builds. The screens cannot tell this apart from PreviewServices.

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../app_services.dart';
import '../bench/frame_meter.dart';
import '../bench/host.dart';
import '../bridges/bridge.dart';
import '../bridges/classifier_adapters.dart';
import '../bridges/dart_preprocessor.dart';
import '../bridges/generator_adapters.dart';
import '../bridges/native_preprocessor_adapter.dart';
import '../bridges/payload_adapters.dart';
import 'frame_source.dart';

class RealServices extends StatefulWidget {
  const RealServices({super.key, required this.child, this.config});

  final Widget child;

  /// Benchmark size. Defaults to [BenchConfig.full], or [BenchConfig.quick]
  /// when built with `--dart-define=QUICK=true`.
  final BenchConfig? config;

  @override
  State<RealServices> createState() => _RealServicesState();
}

class _RealServicesState extends State<RealServices>
    with WidgetsBindingObserver {
  final FrameMeter _meter = FrameMeter();
  late final List<PayloadBridge> _bridges = createPayloadBridges();
  final NativePreprocessorAdapter _native = NativePreprocessorAdapter();
  late final List<Preprocessor> _preprocessors = [
    const DartPreprocessor(),
    _native,
  ];
  late final Map<BridgeKind, Classifier> _classifiers = {
    BridgeKind.methodChannel: ChannelClassifierAdapter(),
    BridgeKind.ffiCopy: LiteRtIsolateClassifier(),
  };
  late final List<TokenGenerator> _generators = [
    BundledSmolGeneratorAdapter(),
    LlamaGeneratorAdapter(),
    ChannelLlamaGeneratorAdapter(),
  ];
  late final RealBenchmark _benchmark = RealBenchmark(
    payloadBridges: _bridges,
    preprocessors: _preprocessors,
    classifierAt: classifierAt,
    generators: _generators,
    frames: () async => (await BundledFrames.load()).frames,
    meter: _meter,
    config:
        widget.config ??
        (const bool.fromEnvironment('QUICK')
            ? BenchConfig.quick
            : BenchConfig.full),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _meter.start();
    // Decode the frames early so the first demo does not wait for them.
    BundledFrames.load().ignore();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) _disposeAll();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disposeAll();
    super.dispose();
  }

  var _disposed = false;

  void _disposeAll() {
    if (_disposed) return;
    _disposed = true;
    _benchmark.dispose();
    _meter.dispose();
    for (final b in _bridges) {
      b.dispose();
    }
    _native.dispose();
    for (final c in _classifiers.values) {
      c.dispose();
    }
    for (final g in _generators) {
      g.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => AppServices(
    payloadBridges: _bridges,
    classifiers: _classifiers,
    preprocessors: _preprocessors,
    generators: _generators,
    frameTimes: _meter.recent,
    jankCount: _meter.jankCount,
    jank: _meter,
    generatorAt: defaultGeneratorAt,
    frames: BundledFrames.loop,
    benchmark: _benchmark,
    classifierAt: classifierAt,
    debugBuild: kDebugMode,
    child: widget.child,
  );
}
