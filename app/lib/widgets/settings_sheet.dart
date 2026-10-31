// A minimal bottom sheet with three radio tiles for the theme-mode choice.
// Opened from the home-screen settings icon. Selecting a tile updates
// [appThemeMode] and persists via [setThemeMode].

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../theme/theme.dart';
import '../theme/theme_mode.dart';
import '../theme/tokens.dart';

/// Shows the theme-mode sheet. Returns when the user dismisses it.
Future<void> showSettingsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    backgroundColor: Palette.paper,
    showDragHandle: true,
    builder: (_) => const _SettingsSheet(),
  );
}

class _SettingsSheet extends StatelessWidget {
  const _SettingsSheet();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Space.gutter,
          0,
          Space.gutter,
          Space.s4,
        ),
        child: ValueListenableBuilder<ThemeMode>(
          valueListenable: appThemeMode,
          builder: (context, current, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(
                  top: Space.s2,
                  bottom: Space.s3,
                ),
                child: Text('Theme', style: AppText.bodyStrong),
              ),
              _ModeTile(
                icon: Symbols.brightness_auto_rounded,
                label: 'Follow system',
                mode: ThemeMode.system,
                current: current,
              ),
              _ModeTile(
                icon: Symbols.light_mode_rounded,
                label: 'Light',
                mode: ThemeMode.light,
                current: current,
              ),
              _ModeTile(
                icon: Symbols.dark_mode_rounded,
                label: 'Dark',
                mode: ThemeMode.dark,
                current: current,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeTile extends StatelessWidget {
  const _ModeTile({
    required this.icon,
    required this.label,
    required this.mode,
    required this.current,
  });

  final IconData icon;
  final String label;
  final ThemeMode mode;
  final ThemeMode current;

  @override
  Widget build(BuildContext context) {
    final selected = mode == current;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.medium),
        onTap: () => setThemeMode(mode),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Space.s2,
            vertical: Space.s3,
          ),
          child: Row(
            children: [
              Icon(icon, size: 24, color: Palette.ink),
              const SizedBox(width: Space.s3),
              Expanded(child: Text(label, style: AppText.body)),
              Icon(
                selected
                    ? Symbols.radio_button_checked_rounded
                    : Symbols.radio_button_unchecked_rounded,
                size: 24,
                color: selected ? Palette.accent : Palette.quiet,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
