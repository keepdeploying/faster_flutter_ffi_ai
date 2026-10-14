// The Material 3 theme, light only, built from the tokens. Projectors wash out
// dark themes, so there is no dark mode. Elevation tints and shadows are off:
// depth comes from hairlines, not from shade.

import 'package:flutter/material.dart';

import 'tokens.dart';

/// Text styles used across the app. Numbers and code identifiers use
/// [mono]-based styles with tabular figures so digits do not jitter while they
/// change.
abstract final class AppText {
  static TextStyle _sans(double size, double weight, {double? height}) =>
      TextStyle(
        fontFamily: Fonts.sans,
        fontSize: size,
        fontWeight: _weight(weight),
        fontVariations: [FontVariation.weight(weight)],
        height: height,
        color: Palette.ink,
      );

  static TextStyle _mono(double size, double weight, {double? height}) =>
      TextStyle(
        fontFamily: Fonts.code,
        fontSize: size,
        fontWeight: _weight(weight),
        fontVariations: [FontVariation.weight(weight)],
        fontFeatures: const [FontFeature.tabularFigures()],
        height: height,
        color: Palette.ink,
      );

  static FontWeight _weight(double w) =>
      FontWeight.values[((w / 100).round() - 1).clamp(0, 8)];

  // Sans
  static final small = _sans(TypeSize.small, 400, height: 1.4);
  static final smallStrong = _sans(TypeSize.small, 600, height: 1.4);
  static final body = _sans(TypeSize.body, 400, height: 1.4);
  static final bodyStrong = _sans(TypeSize.body, 600, height: 1.3);
  static final heading = _sans(TypeSize.heading, 700, height: 1.2);
  static final display = _sans(TypeSize.display, 700, height: 1.05);

  // Google Sans Code, tabular figures
  static final monoSmall = _mono(TypeSize.small, 500, height: 1.4);
  static final monoBody = _mono(TypeSize.body, 500, height: 1.4);
  static final monoBodyStrong = _mono(TypeSize.body, 700, height: 1.3);
  static final monoHeading = _mono(TypeSize.heading, 600, height: 1.15);
  static final monoDisplay = _mono(TypeSize.display, 600, height: 1.0);
  static final monoHero = _mono(TypeSize.hero, 600, height: 1.0);

  /// Same style, quiet colour.
  static TextStyle quiet(TextStyle s) => s.copyWith(color: Palette.quietText);
}

ThemeData buildTheme() {
  const scheme = ColorScheme.light(
    primary: Palette.accent,
    onPrimary: Palette.paper,
    secondary: Palette.ffi,
    onSecondary: Palette.paper,
    error: Palette.channel,
    onError: Palette.paper,
    surface: Palette.paper,
    onSurface: Palette.ink,
    onSurfaceVariant: Palette.quietText,
    outline: Palette.quiet,
    outlineVariant: Palette.line,
    surfaceTint: Color(0x00000000),
    shadow: Color(0x00000000),
  );

  final textTheme = TextTheme(
    displayLarge: AppText.monoHero,
    displayMedium: AppText.monoDisplay,
    headlineLarge: AppText.display,
    headlineMedium: AppText.heading,
    headlineSmall: AppText.heading,
    titleLarge: AppText.heading,
    titleMedium: AppText.bodyStrong,
    titleSmall: AppText.smallStrong,
    bodyLarge: AppText.body,
    bodyMedium: AppText.body,
    bodySmall: AppText.small,
    labelLarge: AppText.bodyStrong,
    labelMedium: AppText.smallStrong,
    labelSmall: AppText.small,
  );

  final shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(Radii.medium),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: Fonts.sans,
    textTheme: textTheme,
    // One icon style everywhere: Material Symbols Rounded, weight 400, optical
    // size 24 (a little heavier than the default 48, which reads thin from the
    // back of a room), outline unless a widget asks for fill.
    iconTheme: const IconThemeData(
      color: Palette.ink,
      weight: 400,
      grade: 0,
      opticalSize: 24,
      fill: 0,
    ),
    scaffoldBackgroundColor: Palette.paper,
    canvasColor: Palette.paper,
    dividerColor: Palette.line,
    dividerTheme: const DividerThemeData(color: Palette.line, thickness: 1),
    splashFactory: NoSplash.splashFactory,
    highlightColor: Palette.accentTint,
    hoverColor: Palette.accentTint,
    focusColor: Palette.accentTint,
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    appBarTheme: const AppBarTheme(
      backgroundColor: Palette.paper,
      surfaceTintColor: Color(0x00000000),
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    cardTheme: const CardThemeData(
      elevation: 0,
      color: Palette.paper,
      surfaceTintColor: Color(0x00000000),
      shadowColor: Color(0x00000000),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Palette.accentStrong,
        foregroundColor: Palette.paper,
        disabledBackgroundColor: Palette.line,
        disabledForegroundColor: Palette.quietText,
        minimumSize: const Size(0, 56),
        padding: const EdgeInsets.symmetric(horizontal: Space.s5),
        textStyle: AppText.bodyStrong,
        elevation: 0,
        shadowColor: const Color(0x00000000),
        surfaceTintColor: const Color(0x00000000),
        shape: shape,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Palette.ink,
        disabledForegroundColor: Palette.quietText,
        minimumSize: const Size(0, 56),
        padding: const EdgeInsets.symmetric(horizontal: Space.s5),
        textStyle: AppText.bodyStrong,
        side: const BorderSide(color: Palette.ink, width: 1.5),
        shape: shape,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: Palette.ink,
        minimumSize: const Size(0, 48),
        textStyle: AppText.bodyStrong,
        shape: shape,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: false,
      hintStyle: AppText.quiet(AppText.body),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Space.s4,
        vertical: Space.s3,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.medium),
        borderSide: const BorderSide(color: Palette.quiet, width: 1.5),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.medium),
        borderSide: const BorderSide(color: Palette.quiet, width: 1.5),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.medium),
        borderSide: const BorderSide(color: Palette.accent, width: 2.5),
      ),
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: Palette.accent,
      selectionColor: Palette.accentTint,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: Palette.accent,
      linearTrackColor: Palette.line,
    ),
  );
}
