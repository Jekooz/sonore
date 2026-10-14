import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'pressable.dart';

/// The pill-shaped action button from the spec's `lib/ui/` list.
///
/// Accent marks the active state only; an inactive pill sits on surfaceRaised
/// with muted text. The glyph is a single Phosphor icon at 24px and the hit
/// area is never smaller than 48x48.
class PillButton extends StatelessWidget {
  const PillButton({
    super.key,
    this.icon,
    required this.onPressed,
    this.isActive = false,
    this.label,
  });

  /// Phosphor glyph. Pass the filled variant when [isActive] is true. Omit it
  /// for a label-only action such as the empty-state button.
  final IconData? icon;

  final VoidCallback? onPressed;
  final bool isActive;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final Color fill = isActive ? Tokens.accent : Tokens.surfaceRaised;
    final TextStyle labelStyle = isActive
        ? Tokens.subtitle.copyWith(color: Tokens.text)
        : Tokens.subtitle;

    return Pressable(
      onTap: onPressed,
      enabled: onPressed != null,
      semanticLabel: label,
      child: AnimatedContainer(
        duration: Tokens.dPress,
        curve: Tokens.curvePress,
        padding: const EdgeInsets.symmetric(
          horizontal: Tokens.s16,
          vertical: Tokens.s8,
        ),
        decoration: ShapeDecoration(color: fill, shape: Tokens.shapePill),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (icon != null)
              Icon(icon, size: Tokens.iconSize, color: Tokens.text),
            if (icon != null && label != null)
              const SizedBox(width: Tokens.s8),
            if (label != null) Text(label!, style: labelStyle),
          ],
        ),
      ),
    );
  }
}
