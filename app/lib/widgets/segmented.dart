// A segmented control drawn by hand so it can carry a colour per option. The
// selected option gets a 16% tint, a 2 px outline in its colour and an ink
// label, so the text stays readable from the back of the room.

import 'package:flutter/material.dart';

import '../theme/theme.dart';
import '../theme/tokens.dart';

class SegmentOption<T> {
  const SegmentOption({
    required this.value,
    required this.label,
    required this.icon,
    this.color = Palette.accent,
    this.tint = Palette.accentTint,
    this.enabled = true,
    this.semanticLabel,
  });

  final T value;
  final String label;
  final IconData icon;
  final Color color;
  final Color tint;
  final bool enabled;
  final String? semanticLabel;
}

class Segmented<T> extends StatelessWidget {
  const Segmented({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.stacked = false,
    this.labelStyle,
  });

  final List<SegmentOption<T>> options;
  final T selected;
  final ValueChanged<T>? onChanged;

  /// Icon above the label, for three or more options on a phone.
  final bool stacked;
  final TextStyle? labelStyle;

  @override
  Widget build(BuildContext context) {
    final style =
        labelStyle ?? (stacked ? AppText.smallStrong : AppText.bodyStrong);
    return Row(
      children: [
        for (var i = 0; i < options.length; i++) ...[
          if (i > 0) const SizedBox(width: Space.s2),
          Expanded(
            // Longer labels get more room, so "Demo generator" is not cut.
            flex: stacked ? 1 : options[i].label.length + 6,
            child: _Segment<T>(
              option: options[i],
              isSelected: options[i].value == selected,
              onTap: onChanged == null || !options[i].enabled
                  ? null
                  : () => onChanged!(options[i].value),
              stacked: stacked,
              style: style,
            ),
          ),
        ],
      ],
    );
  }
}

class _Segment<T> extends StatelessWidget {
  const _Segment({
    required this.option,
    required this.isSelected,
    required this.onTap,
    required this.stacked,
    required this.style,
  });

  final SegmentOption<T> option;
  final bool isSelected;
  final VoidCallback? onTap;
  final bool stacked;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null || isSelected;
    final fg = enabled ? Palette.ink : Palette.quiet;
    final iconColor = isSelected
        ? option.color
        : (enabled ? Palette.quietText : Palette.quiet);
    final icon = Icon(option.icon, size: 24, color: iconColor);
    final label = Text(
      option.label,
      style: style.copyWith(
        color: isSelected ? Palette.ink : fg,
        fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
      ),
      textAlign: TextAlign.center,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    return Semantics(
      button: true,
      selected: isSelected,
      enabled: enabled,
      label: option.semanticLabel ?? option.label,
      excludeSemantics: true,
      child: Material(
        color: isSelected ? option.tint : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.medium),
          side: BorderSide(
            color: isSelected ? option.color : Palette.line,
            width: isSelected ? 2 : 1.5,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.medium),
          onTap: isSelected ? null : onTap,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: stacked ? 72 : 56),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: stacked ? Space.s1 : Space.s2,
                vertical: Space.s2,
              ),
              child: Center(
                child: stacked
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          icon,
                          const SizedBox(height: Space.s1),
                          label,
                        ],
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          icon,
                          const SizedBox(width: Space.s2),
                          Flexible(child: label),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
