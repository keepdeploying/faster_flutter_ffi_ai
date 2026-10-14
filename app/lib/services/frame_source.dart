// Camera-like frames from the photos bundled in assets/frames.
//
// The benchmark and the live demo both use these fixed frames instead of the
// camera, so every run sees exactly the same pixels and the numbers repeat.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import '../bridges/bridge.dart';

/// Decodes every JPEG under `assets/frames/` to tightly packed RGBA, once.
class BundledFrames {
  BundledFrames._(this.frames);

  final List<Frame> frames;

  static Future<BundledFrames>? _loading;

  /// Loads the frames the first time it is called; later calls share them.
  static Future<BundledFrames> load() => _loading ??= _decodeAll();

  static Future<BundledFrames> _decodeAll() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final keys =
        manifest
            .listAssets()
            .where((k) => k.startsWith('assets/frames/') && k.endsWith('.jpg'))
            .toList()
          ..sort();
    if (keys.isEmpty) {
      throw StateError('No frames found under assets/frames/.');
    }
    final frames = <Frame>[];
    for (final key in keys) {
      frames.add(await _decode(await rootBundle.load(key)));
    }
    return BundledFrames._(List.unmodifiable(frames));
  }

  static Future<Frame> _decode(ByteData data) async {
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final image = (await codec.getNextFrame()).image;
    final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final frame = Frame(
      rgba: rgba!.buffer.asUint8List(),
      width: image.width,
      height: image.height,
    );
    image.dispose();
    codec.dispose();
    return frame;
  }

  /// The frames on a loop at [fps], like a camera preview. Cancel the
  /// subscription to stop.
  static Stream<Frame> loop({double fps = 30}) {
    late StreamController<Frame> controller;
    Timer? timer;
    controller = StreamController<Frame>(
      onListen: () async {
        final List<Frame> frames;
        try {
          frames = (await load()).frames;
        } on Object catch (e, s) {
          controller.addError(e, s);
          return;
        }
        if (controller.isClosed) return;
        var i = 0;
        controller.add(frames[0]);
        timer = Timer.periodic(
          Duration(microseconds: (1e6 / fps).round()),
          (_) => controller.add(frames[++i % frames.length]),
        );
      },
      onCancel: () {
        timer?.cancel();
        return controller.close();
      },
    );
    return controller.stream;
  }
}
