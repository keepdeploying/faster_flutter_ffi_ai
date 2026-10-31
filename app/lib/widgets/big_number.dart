import 'package:flutter/material.dart';

import '../theme/theme.dart';
import '../theme/tokens.dart';

/// A number that carries the screen: value in Google Sans Code, a unit beside
/// it and one plain line beneath. [hero] is 72 sp, the one per screen; the
/// smaller form is 44 sp.
class BigNumber extends StatelessWidget {
  const BigNumber({
    super.key,
    required this.value,
    this.unit,
    this.caption,
    this.color,
    this.hero = false,
  });

  final String value;
  final String? unit;
  final String? caption;

  /// Defaults to the current [Palette.ink].
  final Color? color;
  final bool hero;

  @override
  Widget build(BuildContext context) {
    final valueStyle = (hero ? AppText.monoHero : AppText.monoDisplay).copyWith(
      color: color ?? Palette.ink,
    );
    return Semantics(
      label: '${caption ?? ''} $value ${unit ?? ''}'.trim(),
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value, style: valueStyle),
              if (unit != null) ...[
                const SizedBox(width: Space.s2),
                Text(unit!, style: AppText.quiet(AppText.monoBody)),
              ],
            ],
          ),
          if (caption != null)
            Padding(
              padding: const EdgeInsets.only(top: Space.s1),
              child: Text(caption!, style: AppText.quiet(AppText.body)),
            ),
        ],
      ),
    );
  }
}
