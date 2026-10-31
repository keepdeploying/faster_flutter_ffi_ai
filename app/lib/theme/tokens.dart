// Design tokens. One place for every colour, space, size and radius, taken from
// the GDE 2026 slide template so the app and the slides read as one thing.
//
// Colour carries one meaning each, the same as on the slides:
//   orange = anything on the platform-channel path, and over-budget frames.
//            The channel path works; FFI is just faster. Warm orange reads as
//            "classic and established", not "stop or danger".
//   green  = anything on the FFI path (the upgrade)
//   blue   = neutral actions and focus
//   amber  = the frame budget line, nothing else. A distinct hue from the
//            channel orange so the two never read as the same thing.
//
// Bridge-identity colours (channel, ffi, accent, accentStrong, budget, and the
// halftones) stay constant across light and dark so the slide meanings never
// change. Only the neutrals (ink, paper, line, wash, quiet, quietText) flip
// with brightness: they are getters that read [appThemeMode] and the platform
// brightness at call time, so rebuilding the tree after a mode change picks up
// the new values.

import 'package:flutter/material.dart';

import 'theme_mode.dart';

/// Colours. Fills, lines and big numbers may use the strong colours. Small text
/// is always ink, because red and green on white do not reach 4.5:1.
abstract final class Palette {
  // Bridge-identity colours. The same hue in both modes.

  /// Platform-channel path. Google orange 600: warm, legible on both the paper
  /// and the dark backgrounds, distinct from the amber budget line.
  static const channel = Color(0xFFF57C00);
  static const ffi = Color(0xFF34A853);
  static const accent = Color(0xFF4285F4);

  /// The accent, darkened for filled buttons only: white on #4285F4 is 3.6:1,
  /// white on this is 5.4:1, which meets the 4.5:1 rule for the label.
  static const accentStrong = Color(0xFF1967D2);
  static const budget = Color(0xFFF9AB00);

  // Halftone tints, only ever as a 16% fill behind the matching strong colour.
  /// Pale apricot: pairs with the orange channel colour.
  static const channelTint = Color(0x29FFB366);
  static const ffiTint = Color(0x295CDB6D);
  static const accentTint = Color(0x2957CAFF);
  static const budgetTint = Color(0x29FFD427);

  // Light neutrals.
  static const _inkLight = Color(0xFF20344B);
  static const _paperLight = Color(0xFFFFFFFF);
  static const _lineLight = Color(0x1F20344B);
  static const _washLight = Color(0x0F20344B);
  static const _quietLight = Color(0x8C20344B);
  static const _quietTextLight = Color(0xB820344B);

  // Dark neutrals. A near-white ink on a navy-tinted near-black paper, with the
  // same alpha stops applied to the dark ink so lines and quiet text keep the
  // same visual weight as the light scheme.
  static const _inkDark = Color(0xFFE6ECF2);
  static const _paperDark = Color(0xFF0F1C2E);
  static const _lineDark = Color(0x26E6ECF2);
  static const _washDark = Color(0x0FE6ECF2);
  static const _quietDark = Color(0x99E6ECF2);
  static const _quietTextDark = Color(0xC7E6ECF2);

  /// True when the current theme-mode choice and the platform brightness
  /// resolve to a dark surface. In [ThemeMode.system] it reads the OS; in the
  /// explicit modes it ignores the OS.
  static bool get _isDark {
    switch (appThemeMode.value) {
      case ThemeMode.light:
        return false;
      case ThemeMode.dark:
        return true;
      case ThemeMode.system:
        return WidgetsBinding.instance.platformDispatcher.platformBrightness ==
            Brightness.dark;
    }
  }

  static Color get ink => _isDark ? _inkDark : _inkLight;
  static Color get paper => _isDark ? _paperDark : _paperLight;

  /// Grid lines and hairlines.
  static Color get line => _isDark ? _lineDark : _lineLight;

  /// Very light ink fill, for neutral surfaces such as the debug banner.
  static Color get wash => _isDark ? _washDark : _washLight;

  /// Icons and decoration that carry no text.
  static Color get quiet => _isDark ? _quietDark : _quietLight;

  /// Secondary text.
  static Color get quietText => _isDark ? _quietTextDark : _quietTextLight;
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
  static const double gutter = 24;
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
