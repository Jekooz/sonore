import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'pressable.dart';

/// The pill-shaped action button from the spec's `lib/ui/` list.
///
/// Monochrome take: the primary action (active) is a solid white pill with a
/// dark glyph - the app's strongest control - while an inactive pill sits on
/// the thick glass tier with a hairline rim and muted text, so it stays a
/// readable control even when it is placed on a panel that is glass itself.
/// The glyph is a single Phosphor icon at 24px and the hit area is never
/// smaller than 48x48.
class PillButton extends StatelessWidget {
  const PillButton({
    super.key,
    this.icon,
    required this.onPressed,
    this.isActive = false,
    this.label,
    this.tooltip,
  });

  /// Phosphor glyph. Pass the filled variant when [isActive] is true. Omit it
  /// for a label-only action such as the empty-state button.
  final IconData? icon;

  final VoidCallback? onPressed;
  final bool isActive;
  final String? label;

  /// Hover hint and accessible name for icon-only actions: when [label] is
  /// omitted (the compact form narrow headers use), [tooltip] names the
  /// button both for the pointer and for screen readers.
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final Color fill = isActive ? Tokens.text : Tokens.glassThick;
    final TextStyle labelStyle = isActive
        ? Tokens.subtitle.copyWith(color: Tokens.bg)
        : Tokens.subtitle;

    // Active: solid white, the app's strongest control. Inactive: glass tier
    // thick with a hairline rim, so it stays visible when it sits on a panel
    // that is itself glass.
    Widget pill = Pressable(
      onTap: onPressed,
      enabled: onPressed != null,
      semanticLabel: label ?? tooltip,
      child: AnimatedContainer(
        duration: Tokens.dPress,
        curve: Tokens.curvePress,
        // Icon-only pills are square and minimal: 48 px, the touch minimum.
        // Labeled pills keep the generous 16 px gutter.
        padding: EdgeInsets.symmetric(
          horizontal: label == null ? Tokens.s12 : Tokens.s16,
          vertical: Tokens.s8,
        ),
        decoration: ShapeDecoration(
          color: fill,
          shape: isActive
              ? Tokens.shapePill
              : Tokens.shapePill.copyWith(
                  side: BorderSide(
                    color: Tokens.border,
                    width: Tokens.borderWidth,
                  ),
                ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (icon != null)
              Icon(
                icon,
                size: Tokens.iconSize,
                color: isActive ? Tokens.bg : Tokens.text,
              ),
            if (icon != null && label != null) const SizedBox(width: Tokens.s8),
            if (label != null) Text(label!, style: labelStyle),
          ],
        ),
      ),
    );
    if (tooltip != null) {
      pill = Tooltip(message: tooltip!, child: pill);
    }
    return pill;
  }
}
