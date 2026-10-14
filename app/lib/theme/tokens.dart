// Design tokens. One place for every colour, space, size and radius, taken from
// the GDE 2026 slide template so the app and the slides read as one thing.
//
// Colour carries one meaning each, the same as on the slides:
//   red   = anything on the platform-channel path, and over-budget frames
//   green = anything on the FFI path
//   blue  = neutral actions and focus
//   yellow = the 16.7 ms budget line, nothing else

import 'dart:ui';

/// Colours. Fills, lines and big numbers may use the strong colours. Small text
/// is always ink, because red and green on white do not reach 4.5:1.
abstract final class Palette {
  static const ink = Color(0xFF20344B);
  static const paper = Color(0xFFFFFFFF);
  static const channel = Color(0xFFEA4335);
  static const ffi = Color(0xFF34A853);
  static const accent = Color(0xFF4285F4);
  static const budget = Color(0xFFF9AB00);

  /// Secondary text: ink at 72%, which is 5.2:1 on paper. The brief says 55%,
  /// but 55% only reaches 3.3:1, below the 4.5:1 rule for text.
  static const quietText = Color(0xB820344B);

  /// Icons and decoration that carry no text: ink at 55%.
  static const quiet = Color(0x8C20344B);

  /// Grid lines and hairlines: ink at 12%.
  static const line = Color(0x1F20344B);

  /// Very light ink fill, for neutral surfaces such as the debug banner.
  static const wash = Color(0x0F20344B);

  // Halftone tints, only ever as a 16% fill behind the matching strong colour.
  static const channelTint = Color(0x29FF7DAF);
  static const ffiTint = Color(0x295CDB6D);
  static const accentTint = Color(0x2957CAFF);
  static const budgetTint = Color(0x29FFD427);
}

/// Spacing on a 4 / 8 grid.
abstract final class Space {
  static const double s1 = 4;
  static const double s2 = 8;
  static const double s3 = 12;
  static const double s4 = 16;
  static const double s5 = 24;
  static const double s6 = 32;
  static const double s7 = 48;
  static const double s8 = 64;

  /// Side gutter of every screen.
  static const double gutter = 20;
}

/// Type scale in logical pixels (sp): 15 / 20 / 28 / 44 / 72.
abstract final class TypeSize {
  static const double small = 15;
  static const double body = 20;
  static const double heading = 28;
  static const double display = 44;
  static const double hero = 72;
}

abstract final class Radii {
  static const double small = 8;
  static const double medium = 12;
  static const double large = 16;
}

/// Font family names as declared in the pubspec.
abstract final class Fonts {
  static const sans = 'GoogleSansFlex';
  static const code = 'GoogleSansCode';
}
