// The app-wide theme-mode selector and its storage.
//
// A single [ValueNotifier] holds the current choice: follow the system,
// force light, or force dark. Palette neutrals and the [MaterialApp] read it
// through a [ValueListenableBuilder], so flipping it rebuilds the whole tree.
// The value is persisted with [SharedPreferences] under [_prefsKey] and
// reloaded at startup.

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _prefsKey = 'theme_mode';

/// The current theme-mode choice, listened to by [MaterialApp] and by the
/// settings sheet. Defaults to [ThemeMode.system] until a saved value loads.
final ValueNotifier<ThemeMode> appThemeMode = ValueNotifier<ThemeMode>(
  ThemeMode.system,
);

/// Reads the saved preference and applies it to [appThemeMode]. Called once at
/// startup, before building [MaterialApp], so the first frame already matches.
Future<void> loadThemeMode() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_prefsKey);
  appThemeMode.value = _parse(raw);
}

/// Persists [mode] and updates [appThemeMode] so every listener rebuilds.
Future<void> setThemeMode(ThemeMode mode) async {
  appThemeMode.value = mode;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_prefsKey, _encode(mode));
}

ThemeMode _parse(String? raw) => switch (raw) {
  'light' => ThemeMode.light,
  'dark' => ThemeMode.dark,
  _ => ThemeMode.system,
};

String _encode(ThemeMode mode) => switch (mode) {
  ThemeMode.light => 'light',
  ThemeMode.dark => 'dark',
  ThemeMode.system => 'system',
};
