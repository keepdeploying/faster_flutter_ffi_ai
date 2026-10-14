// The deck's look, in one place. Same tokens as docs/ARCHITECTURE.md:
// navy text, red for the platform-channel path, green for the FFI path,
// yellow only for the frame budget.

import 'dart:math' as math;

import 'format.dart';
import 'model.dart';

const String ink = '#20344B';
const String paper = '#FFFFFF';
const String channelRed = '#EA4335';
const String channelRedLight = '#FF7DAF';
const String ffiGreen = '#34A853';
const String ffiGreenDark = '#1E7B34';
const String ffiGreenLight = '#5CDB6D';
const String budgetYellow = '#F9AB00';

/// Secondary text: the ink at 55 percent over white.
const String quiet = '#7B8794';

/// Grid lines: the ink at 12 percent over white.
const String grid = '#DDE0E4';

/// Navy tints for the parts of a classify call that are not the bridge.
const String inkLight = '#C3CAD2';
const String inkMid = '#5B6B7E';

/// Numbers and code names.
const String codeFont = "'Google Sans Code', monospace";

/// Everything else.
const String textFont =
    "'Google Sans Flex', 'Google Sans', Roboto, Helvetica, Arial, sans-serif";

/// How one bridge is drawn.
class BridgeStyle {
  const BridgeStyle(this.color, {this.dash, this.width = 6});

  final String color;

  /// SVG `stroke-dasharray`, or null for a solid line.
  final String? dash;
  final double width;
}

/// The colour of a bridge. Channel kinds are red, FFI kinds are green; the
/// lighter and dashed variants tell the kinds of one family apart.
BridgeStyle styleOf(String bridge) => switch (bridge) {
  'methodChannel' => const BridgeStyle(channelRed),
  'binaryChannel' => const BridgeStyle(channelRedLight),
  'ffiCopy' => const BridgeStyle(ffiGreenDark, dash: '16 9'),
  'ffiLeaf' => const BridgeStyle(ffiGreen),
  'ffiZeroCopy' => const BridgeStyle(ffiGreenLight, dash: '2 11'),
  final other => BridgeStyle(isFfiBridge(other) ? ffiGreen : channelRed),
};

/// The single colour used for a bridge's bar: the family colour.
String barColor(String bridge) => switch (bridge) {
  'binaryChannel' => channelRedLight,
  'ffiCopy' => ffiGreenDark,
  'ffiZeroCopy' => ffiGreenLight,
  _ => isFfiBridge(bridge) ? ffiGreen : channelRed,
};

/// A readable text colour for a bridge name: light tints use the ink.
String labelColor(String bridge) => switch (bridge) {
  'binaryChannel' || 'ffiZeroCopy' => ink,
  final b => barColor(b),
};

const int chartWidth = 1600;
const int chartHeight = 900;

/// The line under every chart: where the numbers come from.
String sourceLine(Results r) {
  final d = r.device;
  return '${d.model} · ${d.platform} ${d.os} · ${d.abi} · '
      'Flutter ${r.flutter} · ${r.buildMode} build · ${r.date}';
}

/// Wraps [body] in a 1600x900 SVG with the title block and the source line.
///
/// [title] and [subtitle] sit at the top left; the source line at the bottom
/// left. [body] is drawn in absolute coordinates inside the 1600x900 box.
String chartFrame({
  required String title,
  required String subtitle,
  required String source,
  required String body,
  String? description,
}) {
  final buf = StringBuffer()
    ..writeln(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $chartWidth '
      '$chartHeight" width="$chartWidth" height="$chartHeight" role="img" '
      'aria-labelledby="t d">',
    )
    ..writeln('<title id="t">${xmlEscape(title)}</title>')
    ..writeln('<desc id="d">${xmlEscape(description ?? subtitle)}</desc>')
    ..writeln('<rect width="$chartWidth" height="$chartHeight" fill="$paper"/>')
    ..writeln(
      '<text x="80" y="92" font-family="$textFont" font-size="48" '
      'font-weight="700" fill="$ink">${xmlEscape(title)}</text>',
    )
    ..writeln(
      '<text x="80" y="140" font-family="$textFont" font-size="28" '
      'fill="$quiet">${xmlEscape(subtitle)}</text>',
    )
    ..write(body)
    ..writeln(
      '<text x="80" y="868" font-family="$codeFont" font-size="20" '
      'fill="$quiet">${xmlEscape(source)}</text>',
    )
    ..writeln('</svg>');
  return buf.toString();
}

double _channel(int v) {
  final c = v / 255;
  return c <= 0.03928
      ? c / 12.92
      : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
}

double _luminance(String hex) {
  final v = int.parse(hex.substring(1), radix: 16);
  return 0.2126 * _channel((v >> 16) & 255) +
      0.7152 * _channel((v >> 8) & 255) +
      0.0722 * _channel(v & 255);
}

/// Contrast ratio of two `#rrggbb` colours, 1 to 21.
double contrast(String a, String b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// White or ink text, whichever reads better on [background].
String onColor(String background) =>
    contrast(paper, background) >= contrast(ink, background) ? paper : ink;
