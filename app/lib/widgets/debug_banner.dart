import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../app_services.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';

/// A slim notice on measurement screens in debug mode. Debug builds run slower
/// than the code the talk is about, so the numbers would mislead.
class DebugBanner extends StatelessWidget {
  const DebugBanner({super.key});

  static const message =
      'Debug build: numbers are not representative. Run with --profile.';

  @override
  Widget build(BuildContext context) {
    if (!AppServices.of(context).debugBuild) return const SizedBox.shrink();
    return Semantics(
      container: true,
      label: message,
      excludeSemantics: true,
      child: Container(
        width: double.infinity,
        color: Palette.wash,
        padding: const EdgeInsets.symmetric(
          horizontal: Space.gutter,
          vertical: Space.s2,
        ),
        child: Row(
          children: [
            const Icon(Symbols.info_rounded, size: 20, color: Palette.ink),
            const SizedBox(width: Space.s2),
            Expanded(child: Text(message, style: AppText.small)),
          ],
        ),
      ),
    );
  }
}
