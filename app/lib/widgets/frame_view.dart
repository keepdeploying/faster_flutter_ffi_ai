import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../bridges/bridge.dart';
import '../theme/tokens.dart';

/// Shows a [Frame] (tightly packed RGBA) as an image. Decoding is async, so it
/// keeps the previous picture on screen until the next one is ready.
class FrameView extends StatefulWidget {
  const FrameView({super.key, required this.frame, this.size = 136});

  final Frame? frame;
  final double size;

  @override
  State<FrameView> createState() => _FrameViewState();
}

class _FrameViewState extends State<FrameView> {
  ui.Image? _image;
  var _serial = 0;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(FrameView old) {
    super.didUpdateWidget(old);
    if (!identical(old.frame, widget.frame)) _decode();
  }

  void _decode() {
    final f = widget.frame;
    if (f == null) return;
    final serial = ++_serial;
    ui.decodeImageFromPixels(
      f.rgba,
      f.width,
      f.height,
      ui.PixelFormat.rgba8888,
      (image) {
        if (!mounted || serial != _serial) {
          image.dispose();
          return;
        }
        setState(() {
          _image?.dispose();
          _image = image;
        });
      },
    );
  }

  @override
  void dispose() {
    _serial++;
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Current test frame',
      image: true,
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: Palette.wash,
          borderRadius: BorderRadius.circular(Radii.medium),
          border: Border.all(color: Palette.line, width: 1.5),
        ),
        clipBehavior: Clip.antiAlias,
        child: _image == null
            ? null
            : RawImage(
                image: _image,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
              ),
      ),
    );
  }
}
