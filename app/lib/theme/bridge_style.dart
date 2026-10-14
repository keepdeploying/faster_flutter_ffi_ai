// How each bridge looks everywhere it appears: one colour, one icon, one short
// label. Red for channels, green for FFI, so a glance at any screen tells which
// path a number belongs to.

import 'package:flutter/widgets.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../bridges/bridge.dart';
import 'tokens.dart';

class BridgeStyle {
  const BridgeStyle({
    required this.color,
    required this.tint,
    required this.icon,
    required this.label,
    required this.longLabel,
  });

  /// Strong colour for marks, bars and big numbers.
  final Color color;

  /// The matching 16% halftone fill.
  final Color tint;
  final IconData icon;

  /// Short, for segmented controls and table rows.
  final String label;

  /// The full name used in the bridge enum, for screen readers and captions.
  final String longLabel;

  static BridgeStyle of(BridgeKind kind) => switch (kind) {
    BridgeKind.methodChannel => const BridgeStyle(
      color: Palette.channel,
      tint: Palette.channelTint,
      icon: Symbols.mail_rounded,
      label: 'Channel',
      longLabel: 'MethodChannel',
    ),
    BridgeKind.binaryChannel => const BridgeStyle(
      color: Palette.channel,
      tint: Palette.channelTint,
      icon: Symbols.package_2_rounded,
      label: 'Binary',
      longLabel: 'BinaryCodec channel',
    ),
    BridgeKind.ffiCopy => const BridgeStyle(
      color: Palette.ffi,
      tint: Palette.ffiTint,
      icon: Symbols.content_copy_rounded,
      label: 'FFI copy',
      longLabel: 'FFI + copy',
    ),
    BridgeKind.ffiLeaf => const BridgeStyle(
      color: Palette.ffi,
      tint: Palette.ffiTint,
      icon: Symbols.bolt_rounded,
      label: 'FFI leaf',
      longLabel: 'FFI leaf',
    ),
    BridgeKind.ffiZeroCopy => const BridgeStyle(
      color: Palette.ffi,
      tint: Palette.ffiTint,
      icon: Symbols.near_me_rounded,
      label: 'FFI zero-copy',
      longLabel: 'FFI zero-copy',
    ),
  };
}

/// Where a classifier runs. Not a path, so it uses the neutral accent.
class SiteStyle {
  const SiteStyle({required this.icon, required this.label});

  final IconData icon;
  final String label;

  static SiteStyle of(ExecutionSite site) => switch (site) {
    ExecutionSite.uiThread => const SiteStyle(
      icon: Symbols.web_asset_rounded,
      label: 'UI thread',
    ),
    ExecutionSite.isolate => const SiteStyle(
      icon: Symbols.call_split_rounded,
      label: 'Isolate',
    ),
    ExecutionSite.nativeThread => const SiteStyle(
      icon: Symbols.memory_rounded,
      label: 'Native thread',
    ),
  };
}
