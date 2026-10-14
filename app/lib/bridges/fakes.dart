// Deterministic stand-ins for every interface in bridge.dart. Tests use them,
// and so do the screens in debug previews, so the UI can be built and checked
// without a phone, a model or a native library.

import 'dart:async';
import 'dart:typed_data';

import 'bridge.dart';

/// Busy-waits [micros] on a stopwatch. A sleep would be too coarse for the
/// microsecond latencies the benchmark tests need.
void _spin(double micros) {
  if (micros <= 0) return;
  final sw = Stopwatch()..start();
  while (sw.elapsedTicks * 1e6 / sw.frequency < micros) {}
}

/// A [PayloadBridge] whose latency is `fixedMicros + bytes * perByteNanos`.
///
/// FFI kinds answer synchronously, channel kinds with a [Future], like the real
/// ones. The checksum is the real one, unless [corruptChecksum] is set, which
/// makes every answer wrong (to test that the runner notices).
class FakePayloadBridge implements PayloadBridge {
  FakePayloadBridge(
    this.kind, {
    this.perByteNanos = 0,
    this.fixedMicros = 0,
    this.corruptChecksum = false,
  });

  @override
  final BridgeKind kind;
  final double perByteNanos;
  final double fixedMicros;
  final bool corruptChecksum;

  int calls = 0;
  int? warmedUpBytes;
  bool disposed = false;

  @override
  Future<void> warmUp(int maxBytes) async {
    warmedUpBytes = maxBytes;
  }

  @override
  FutureOr<int> roundTrip(Uint8List payload) {
    calls++;
    _spin(fixedMicros + payload.length * perByteNanos / 1000.0);
    var sum = checksum(payload);
    if (corruptChecksum) sum = (sum + 1) & 0xFFFFFFFF;
    if (kind.isFfi) return sum;
    return Future<int>.value(sum);
  }

  @override
  void dispose() {
    disposed = true;
  }
}

/// A small frame with a smooth, repeatable pattern: for tests and previews.
Frame makeFakeFrame({int width = 64, int height = 48, int seed = 1}) {
  final rgba = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = (y * width + x) * 4;
      rgba[i] = (x * 255 ~/ (width > 1 ? width - 1 : 1) + seed * 17) & 0xFF;
      rgba[i + 1] =
          (y * 255 ~/ (height > 1 ? height - 1 : 1) + seed * 31) & 0xFF;
      rgba[i + 2] = ((x + y) * 5 + seed * 53) & 0xFF;
      rgba[i + 3] = 0xFF;
    }
  }
  return Frame(rgba: rgba, width: width, height: height);
}

/// A [Classifier] that picks a label from the frame's bytes and reports a fixed
/// time split (plus a small repeating wobble, so percentiles are not all equal).
class FakeClassifier implements Classifier {
  FakeClassifier({
    this.kind = BridgeKind.ffiCopy,
    this.preprocessMicros = 300,
    this.inferenceMicros = 2000,
    this.bridgeMicros = 150,
    this.labels = const ['cat', 'dog', 'bird', 'car', 'tree'],
    this.simulateLatency = false,
  });

  @override
  final BridgeKind kind;
  final int preprocessMicros;
  final int inferenceMicros;
  final int bridgeMicros;
  final List<String> labels;

  /// When true, `classify` also waits the reported total (for previews).
  final bool simulateLatency;

  bool loaded = false;
  bool disposed = false;
  int _calls = 0;

  @override
  Future<void> load() async {
    loaded = true;
  }

  @override
  Future<Classification> classify(Frame frame) async {
    if (!loaded) throw StateError('FakeClassifier: call load() first');
    final wobble = (_calls++ % 5) * 10;
    final inference = inferenceMicros + wobble;
    final total = preprocessMicros + inference + bridgeMicros;
    if (simulateLatency) {
      await Future<void>.delayed(Duration(microseconds: total));
    }
    var sum = 0;
    final step = (frame.rgba.length ~/ 512).clamp(1, frame.rgba.length);
    for (var i = 0; i < frame.rgba.length; i += step) {
      sum += frame.rgba[i];
    }
    final index = sum % labels.length;
    return Classification(
      labelIndex: index,
      label: labels[index],
      confidence: 0.5 + ((index * 7) % 50) / 100.0,
      totalMicros: total,
      preprocessMicros: preprocessMicros,
      inferenceMicros: inference,
    );
  }

  @override
  void dispose() {
    disposed = true;
  }
}

/// A [TokenGenerator] that streams words from a fixed vocabulary, one every
/// [tokenDelay], starting at a point chosen from the prompt.
class FakeTokenGenerator implements TokenGenerator {
  FakeTokenGenerator({
    this.tokenDelay = const Duration(milliseconds: 2),
    this.isRealModel = false,
    this.label = 'Fake generator',
  });

  static const List<String> vocabulary = [
    'Dart',
    'talks',
    'to',
    'native',
    'code',
    'without',
    'a',
    'detour',
    'through',
    'channels',
  ];

  final Duration tokenDelay;

  @override
  final bool isRealModel;

  @override
  final String label;

  bool loaded = false;
  bool disposed = false;
  int _run = 0;

  @override
  Future<void> load() async {
    loaded = true;
  }

  @override
  Stream<String> generate(String prompt, {int maxTokens = 128}) async* {
    if (!loaded) throw StateError('FakeTokenGenerator: call load() first');
    final run = ++_run;
    var seed = 0;
    for (final c in prompt.codeUnits) {
      seed = (seed * 31 + c) & 0xFFFF;
    }
    for (var i = 0; i < maxTokens; i++) {
      await Future<void>.delayed(tokenDelay);
      if (run != _run) return;
      yield '${vocabulary[(seed + i) % vocabulary.length]} ';
    }
  }

  @override
  Future<void> cancel() async {
    _run++;
  }

  @override
  void dispose() {
    disposed = true;
    _run++;
  }
}
