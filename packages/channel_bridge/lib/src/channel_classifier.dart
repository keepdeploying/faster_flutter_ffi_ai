import 'package:flutter/services.dart';

import 'channel_names.dart';

/// Where the native side runs the work after the call arrives.
enum ChannelSite {
  /// A single background thread on the native side. The platform thread only
  /// receives the call and posts the reply. This is the default.
  backgroundThread,

  /// The platform thread itself. With merged threads (Flutter 3.29+ on mobile)
  /// that is the UI thread too, so frames stop while the model runs. Used by
  /// the jank demo.
  platformThread,
}

/// One classification result, with the time split.
class ChannelClassification {
  const ChannelClassification({
    required this.index,
    required this.label,
    required this.confidence,
    required this.preprocessMicros,
    required this.inferenceMicros,
    required this.totalMicros,
  });

  /// Parses the reply of the `classify` method. Numbers may arrive as `int` or
  /// `double` depending on the platform, so they are read as `num`.
  factory ChannelClassification.fromReply(
    Map<Object?, Object?> reply, {
    required int totalMicros,
  }) {
    num number(String key) {
      final value = reply[key];
      if (value is num) return value;
      throw FormatException('classify reply has no number "$key": $reply');
    }

    final label = reply['label'];
    if (label is! String) {
      throw FormatException('classify reply has no string "label": $reply');
    }
    return ChannelClassification(
      index: number('index').toInt(),
      label: label,
      confidence: number('confidence').toDouble(),
      preprocessMicros: number('preprocessUs').toInt(),
      inferenceMicros: number('inferenceUs').toInt(),
      totalMicros: totalMicros,
    );
  }

  final int index;
  final String label;
  final double confidence;

  /// Measured on the native side with the monotonic clock.
  final int preprocessMicros;

  /// Measured on the native side around the model's `run`/`invoke`.
  final int inferenceMicros;

  /// Measured in Dart, from the call to the reply.
  final int totalMicros;

  @override
  String toString() =>
      'ChannelClassification($index "$label" ${confidence.toStringAsFixed(3)}, '
      'pre ${preprocessMicros}us, inf ${inferenceMicros}us, total ${totalMicros}us)';
}

/// Runs the bundled .tflite model in Kotlin (LiteRT) over a `MethodChannel`.
///
/// Every frame is encoded, copied to the platform side, decoded, resized to
/// 224x224 natively, run through the model and answered with a small map.
class ChannelClassifier {
  /// [messenger] is for tests.
  ChannelClassifier({BinaryMessenger? messenger})
    : _channel = MethodChannel(
        ChannelNames.method,
        const StandardMethodCodec(),
        messenger,
      );

  final MethodChannel _channel;
  bool _loaded = false;

  /// Loads the model and its labels from Flutter assets. The keys are the
  /// paths declared in the app's pubspec, e.g. `assets/models/labels.txt`.
  ///
  /// [threads] is the number of CPU threads the model runtime may use. Use the
  /// same number on the FFI path so the comparison stays fair.
  Future<void> load({
    required String modelAssetKey,
    required String labelsAssetKey,
    int threads = 4,
  }) async {
    await _channel.invokeMethod<void>(ChannelNames.loadModel, <String, Object?>{
      'model': modelAssetKey,
      'labels': labelsAssetKey,
      'threads': threads,
    });
    _loaded = true;
  }

  /// Marks this classifier ready without loading again. The native side keeps
  /// one model per Flutter engine, so a classifier in a background isolate
  /// (via `BackgroundIsolateBinaryMessenger`) can use the model the main
  /// isolate already loaded.
  void markLoaded() => _loaded = true;

  /// Classifies one tightly packed RGBA8888 frame.
  Future<ChannelClassification> classify(
    Uint8List rgba,
    int width,
    int height, {
    ChannelSite site = ChannelSite.backgroundThread,
  }) async {
    if (!_loaded) {
      throw StateError('ChannelClassifier.load() has not completed');
    }
    final watch = Stopwatch()..start();
    final reply = await _channel.invokeMapMethod<Object?, Object?>(
      ChannelNames.classify,
      <String, Object?>{
        'rgba': rgba,
        'width': width,
        'height': height,
        'site': site == ChannelSite.platformThread ? 'platform' : 'background',
      },
    );
    watch.stop();
    if (reply == null) {
      throw PlatformException(
        code: 'null_reply',
        message: 'classify returned null',
      );
    }
    return ChannelClassification.fromReply(
      reply,
      totalMicros: watch.elapsedMicroseconds,
    );
  }

  /// Safe to call twice. The native model stays loaded until the engine detaches.
  void dispose() {
    _loaded = false;
  }
}
