// Tiny helpers that write SVG elements as strings.

import 'format.dart';
import 'theme.dart';

/// A `<text>` element.
String svgText(
  double x,
  double y,
  String text, {
  double size = 24,
  String fill = ink,
  String anchor = 'start',
  bool bold = false,
  bool code = false,
  String? extra,
}) {
  return '<text x="${num2(x)}" y="${num2(y)}" font-family="'
      '${code ? codeFont : textFont}" font-size="${num2(size)}" fill="$fill"'
      '${anchor == 'start' ? '' : ' text-anchor="$anchor"'}'
      '${bold ? ' font-weight="700"' : ''}${extra == null ? '' : ' $extra'}>'
      '${xmlEscape(text)}</text>\n';
}

/// A `<line>`.
String svgLine(
  double x1,
  double y1,
  double x2,
  double y2, {
  String stroke = ink,
  double width = 2,
  String? dash,
  String? extra,
}) {
  return '<line x1="${num2(x1)}" y1="${num2(y1)}" x2="${num2(x2)}" '
      'y2="${num2(y2)}" stroke="$stroke" stroke-width="${num2(width)}"'
      '${dash == null ? '' : ' stroke-dasharray="$dash"'}'
      '${extra == null ? '' : ' $extra'}/>\n';
}

/// A `<rect>`.
String svgRect(
  double x,
  double y,
  double w,
  double h, {
  String fill = ink,
  double radius = 0,
  String? extra,
}) {
  return '<rect x="${num2(x)}" y="${num2(y)}" width="${num2(w)}" '
      'height="${num2(h)}" fill="$fill"'
      '${radius == 0 ? '' : ' rx="${num2(radius)}"'}'
      '${extra == null ? '' : ' $extra'}/>\n';
}
