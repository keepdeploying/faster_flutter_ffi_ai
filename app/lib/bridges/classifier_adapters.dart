// The same MobileNet model, the same frames, two bridges.
//
// Channel: Dart sends the frame to Kotlin or Swift, which preprocesses it, runs
// LiteRT and sends the label back. FFI: Dart calls C to preprocess the frame
// straight into LiteRT's input tensor, then calls LiteRT's C API to run it.
// Both sides use LiteRT on the CPU with 4 threads and no GPU delegate, so the
// only difference is how the call gets there.

import 'dart:async';
import 'dart:developer' show Timeline;
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:channel_bridge/channel_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_litert/flutter_litert.dart';

import 'bridge.dart';
import 'native_preprocessor_adapter.dart';

const modelAsset = 'assets/models/mobilenet_v1_1.0_224.tflite';
const labelsAsset = 'assets/models/labels.txt';
const modelThreads = 4;
const inputSize = 224;

Future<List<String>> _loadLabels() async =>
    (await rootBundle.loadString(labelsAsset)).split('\n');

/// The platform-channel classifier. [site] picks the native thread:
///
/// - [ExecutionSite.uiThread]: the platform thread. Since Flutter 3.29 on
///   Android and iOS, the platform thread and the UI thread are the same
///   thread, so frames stop while the model runs.
/// - [ExecutionSite.nativeThread]: a background thread in Kotlin or Swift.
/// - [ExecutionSite.isolate]: the call leaves from a background isolate
///   (`BackgroundIsolateBinaryMessenger`) and runs on the native background
///   thread. Channels cannot run the native work inside a Dart isolate, so
///   this measures the extra hop, not a different place for the work.
class ChannelClassifierAdapter implements Classifier {
  ChannelClassifierAdapter({this.site = ExecutionSite.nativeThread});

  final ExecutionSite site;
  final ChannelClassifier _channel = ChannelClassifier();
  List<String> _labels = const [];
  _ChannelIsolate? _isolate;

  @override
  BridgeKind get kind => BridgeKind.methodChannel;

  @override
  Future<void> load() async {
    _labels = await _loadLabels();
    await _channel.load(
      modelAssetKey: modelAsset,
      labelsAssetKey: labelsAsset,
      threads: modelThreads,
    );
    if (site == ExecutionSite.isolate) _isolate = await _ChannelIsolate.spawn();
  }

  @override
  Future<Classification> classify(Frame frame) async {
    if (site == ExecutionSite.isolate) {
      final r = await _isolate!.classify(frame);
      return _toClassification(r, _labels);
    }
    final r = await _channel.classify(
      frame.rgba,
      frame.width,
      frame.height,
      site: site == ExecutionSite.uiThread
          ? ChannelSite.platformThread
          : ChannelSite.backgroundThread,
    );
    return Classification(
      labelIndex: r.index,
      label: r.label,
      confidence: r.confidence,
      totalMicros: r.totalMicros,
      preprocessMicros: r.preprocessMicros,
      inferenceMicros: r.inferenceMicros,
    );
  }

  @override
  void dispose() {
    _isolate?.close();
    _isolate = null;
    _channel.dispose();
  }
}

Classification _toClassification(_Reply r, List<String> labels) =>
    Classification(
      labelIndex: r.index,
      label: r.index < labels.length ? labels[r.index] : '#${r.index}',
      confidence: r.confidence,
      totalMicros: r.totalMicros,
      preprocessMicros: r.preprocessMicros,
      inferenceMicros: r.inferenceMicros,
    );

/// The FFI classifier, running synchronously on the calling (UI) isolate.
///
/// The call blocks the UI thread for as long as preprocessing and inference
/// take: that is the point of the "UI thread" demo.
class LiteRtFfiClassifier implements Classifier {
  final _FfiModel _model = _FfiModel();
  List<String> _labels = const [];

  @override
  BridgeKind get kind => BridgeKind.ffiCopy;

  @override
  Future<void> load() async {
    _labels = await _loadLabels();
    final bytes = await rootBundle.load(modelAsset);
    _model.open(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
  }

  @override
  Future<Classification> classify(Frame frame) async {
    final watch = Stopwatch()..start();
    // Named so it shows under Timeline events in DevTools.
    Timeline.startSync('classify: ffi');
    final _Reply r;
    try {
      r = _model.run(frame);
    } finally {
      Timeline.finishSync();
    }
    watch.stop();
    return _toClassification(r.withTotal(watch.elapsedMicroseconds), _labels);
  }

  @override
  void dispose() => _model.close();
}

/// The FFI classifier in a long-lived worker isolate.
///
/// FFI objects belong to one isolate, so the worker opens its own LiteRT
/// interpreter and its own C preprocessor. Frames go over as
/// `TransferableTypedData` (moved, not copied); the label comes back.
///
/// LiteRT's Flutter package has no API that runs a model on a thread outside
/// the Dart isolates, so [ExecutionSite.nativeThread] uses this worker too and
/// says so in [siteNote].
class LiteRtIsolateClassifier implements Classifier {
  LiteRtIsolateClassifier({this.site = ExecutionSite.isolate});

  final ExecutionSite site;
  _FfiIsolate? _worker;
  List<String> _labels = const [];

  String get siteNote => site == ExecutionSite.nativeThread
      ? 'Runs in a worker isolate: LiteRT for Flutter has no native-thread API'
      : 'Runs in a worker isolate';

  @override
  BridgeKind get kind => BridgeKind.ffiCopy;

  @override
  Future<void> load() async {
    _labels = await _loadLabels();
    final bytes = await rootBundle.load(modelAsset);
    _worker = await _FfiIsolate.spawn(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
  }

  @override
  Future<Classification> classify(Frame frame) async {
    final watch = Stopwatch()..start();
    final r = await _worker!.classify(frame);
    watch.stop();
    return _toClassification(r.withTotal(watch.elapsedMicroseconds), _labels);
  }

  @override
  void dispose() {
    _worker?.close();
    _worker = null;
  }
}

/// Builds the classifier for one bridge at one execution site.
Classifier classifierAt(BridgeKind kind, ExecutionSite site) => kind.isFfi
    ? (site == ExecutionSite.uiThread
          ? LiteRtFfiClassifier()
          : LiteRtIsolateClassifier(site: site))
    : ChannelClassifierAdapter(site: site);

// ---------------------------------------------------------------------------

class _Reply {
  const _Reply(
    this.index,
    this.confidence,
    this.preprocessMicros,
    this.inferenceMicros, [
    this.totalMicros = 0,
  ]);

  final int index;
  final double confidence;
  final int preprocessMicros;
  final int inferenceMicros;
  final int totalMicros;

  _Reply withTotal(int total) =>
      _Reply(index, confidence, preprocessMicros, inferenceMicros, total);

  List<Object> toMessage() => [
    index,
    confidence,
    preprocessMicros,
    inferenceMicros,
  ];

  static _Reply fromMessage(List<Object?> m) => _Reply(
    m[0]! as int,
    m[1]! as double,
    m[2]! as int,
    m[3]! as int,
    m.length > 4 ? m[4]! as int : 0,
  );
}

/// One LiteRT interpreter plus the C preprocessor, used by one isolate.
class _FfiModel {
  Interpreter? _interpreter;
  late Float32List _input;
  late Tensor _output;
  final NativePreprocessorAdapter _pre = NativePreprocessorAdapter();

  void open(Uint8List modelBytes) {
    final options = InterpreterOptions()..threads = modelThreads;
    final interpreter = Interpreter.fromBuffer(modelBytes, options: options);
    interpreter.allocateTensors();
    // A Float32List over the input tensor's own native memory: C writes the
    // preprocessed frame straight into it.
    _input = interpreter.getInputTensor(0).asFloat32View();
    _output = interpreter.getOutputTensor(0);
    _interpreter = interpreter;
  }

  _Reply run(Frame frame) {
    final interpreter = _interpreter;
    if (interpreter == null) throw StateError('Call load() first.');
    final watch = Stopwatch()..start();
    _pre.preprocessInto(frame, _input, size: inputSize);
    final preprocessed = watch.elapsedMicroseconds;
    interpreter.invoke();
    final invoked = watch.elapsedMicroseconds;
    final scores = _output.asFloat32View();
    var best = 0;
    for (var i = 1; i < scores.length; i++) {
      if (scores[i] > scores[best]) best = i;
    }
    return _Reply(
      best,
      _softmaxOf(scores, best),
      preprocessed,
      invoked - preprocessed,
    );
  }

  void close() {
    _interpreter?.close();
    _interpreter = null;
    _pre.dispose();
  }
}

/// MobileNet V1's float model ends in a softmax already; this guards against
/// a model that returns logits, so the confidence shown is always in [0, 1].
double _softmaxOf(Float32List scores, int index) {
  var sum = 0.0;
  var allProbabilities = true;
  for (final s in scores) {
    if (s < 0 || s > 1) allProbabilities = false;
    sum += s;
  }
  if (allProbabilities && (sum - 1).abs() < 0.05) return scores[index];
  final max = scores[index];
  var expSum = 0.0;
  for (final s in scores) {
    expSum += math.exp(s - max);
  }
  return 1 / expSum;
}

/// A worker isolate that owns one [_FfiModel].
class _FfiIsolate {
  _FfiIsolate._(this._isolate, this._send, this._replies);

  final Isolate _isolate;
  final SendPort _send;
  final StreamQueue _replies;

  static Future<_FfiIsolate> spawn(Uint8List modelBytes) async {
    final port = ReceivePort();
    final isolate = await Isolate.spawn(_ffiWorker, [
      port.sendPort,
      TransferableTypedData.fromList([modelBytes]),
    ], debugName: 'ffi-classifier');
    final replies = StreamQueue(port);
    final send = await replies.next as SendPort;
    final ready = await replies.next;
    if (ready is String) {
      isolate.kill();
      throw StateError('FFI worker failed to load the model: $ready');
    }
    return _FfiIsolate._(isolate, send, replies);
  }

  Future<_Reply> classify(Frame frame) async {
    _send.send([
      TransferableTypedData.fromList([frame.rgba]),
      frame.width,
      frame.height,
    ]);
    final reply = await _replies.next;
    if (reply is String) throw StateError(reply);
    return _Reply.fromMessage(reply as List<Object?>);
  }

  void close() {
    _send.send(null);
    _replies.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }
}

void _ffiWorker(List<Object?> args) {
  final out = args[0]! as SendPort;
  final inbox = ReceivePort();
  out.send(inbox.sendPort);
  final model = _FfiModel();
  try {
    model.open((args[1]! as TransferableTypedData).materialize().asUint8List());
    out.send(true);
  } on Object catch (e) {
    out.send('$e');
    inbox.close();
    return;
  }
  inbox.listen((message) {
    if (message == null) {
      model.close();
      inbox.close();
      return;
    }
    final m = message as List<Object?>;
    try {
      final rgba = (m[0]! as TransferableTypedData).materialize().asUint8List();
      final frame = Frame(
        rgba: rgba,
        width: m[1]! as int,
        height: m[2]! as int,
      );
      Timeline.startSync('classify: ffi (isolate)');
      final _Reply r;
      try {
        r = model.run(frame);
      } finally {
        Timeline.finishSync();
      }
      out.send(r.toMessage());
    } on Object catch (e) {
      out.send('$e');
    }
  });
}

/// A background isolate that sends channel calls, for [ExecutionSite.isolate].
class _ChannelIsolate {
  _ChannelIsolate._(this._isolate, this._send, this._replies);

  final Isolate _isolate;
  final SendPort _send;
  final StreamQueue _replies;

  static Future<_ChannelIsolate> spawn() async {
    final port = ReceivePort();
    final token = RootIsolateToken.instance!;
    final isolate = await Isolate.spawn(_channelWorker, [
      port.sendPort,
      token,
    ], debugName: 'channel-caller');
    final replies = StreamQueue(port);
    final send = await replies.next as SendPort;
    return _ChannelIsolate._(isolate, send, replies);
  }

  Future<_Reply> classify(Frame frame) async {
    final watch = Stopwatch()..start();
    _send.send([
      TransferableTypedData.fromList([frame.rgba]),
      frame.width,
      frame.height,
    ]);
    final reply = await _replies.next;
    watch.stop();
    if (reply is String) throw StateError(reply);
    return _Reply.fromMessage(reply as List<Object?>)
        .withTotal(watch.elapsedMicroseconds);
  }

  void close() {
    _send.send(null);
    _replies.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }
}

void _channelWorker(List<Object?> args) {
  final out = args[0]! as SendPort;
  BackgroundIsolateBinaryMessenger.ensureInitialized(
    args[1]! as RootIsolateToken,
  );
  final channel = ChannelClassifier(
    messenger: BackgroundIsolateBinaryMessenger.instance,
  );
  // The model is already loaded natively by the main isolate's classifier;
  // this marks the Dart side as ready without loading it again.
  channel.markLoaded();
  final inbox = ReceivePort();
  out.send(inbox.sendPort);
  inbox.listen((message) async {
    if (message == null) {
      inbox.close();
      return;
    }
    final m = message as List<Object?>;
    try {
      final rgba = (m[0]! as TransferableTypedData).materialize().asUint8List();
      final r = await channel.classify(rgba, m[1]! as int, m[2]! as int);
      out.send([r.index, r.confidence, r.preprocessMicros, r.inferenceMicros]);
    } on Object catch (e) {
      out.send('$e');
    }
  });
}

/// The smallest pull-based queue over a stream, so a worker's replies can be
/// awaited one at a time without package:async.
class StreamQueue {
  StreamQueue(Stream<Object?> stream) {
    _sub = stream.listen((event) {
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete(event);
      } else {
        _buffer.add(event);
      }
    });
  }

  late final StreamSubscription<Object?> _sub;
  final List<Object?> _buffer = [];
  final List<Completer<Object?>> _waiting = [];

  Future<Object?> get next {
    if (_buffer.isNotEmpty) return Future.value(_buffer.removeAt(0));
    final c = Completer<Object?>();
    _waiting.add(c);
    return c.future;
  }

  void close() => _sub.cancel();
}
