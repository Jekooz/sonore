import 'package:flutter/material.dart';

import '../../routing/destinations.dart';
import '../../theme/icons.dart';
import '../../theme/tokens.dart';
import '../../ui/glass_surface.dart';

/// Phone navigation.
///
/// Spec: "Phone: glass bottom bar (pill, active icon filled and accented) with
/// the mini player docked just above it." Touch targets stay at or above
/// [Tokens.minTouchTarget].
///
/// Settings is a trailing action rather than a fifth destination: the spec
/// keeps four destinations but lists Settings in the navigation menu, so it
/// gets its own divided slot instead of changing what a tab is.
class NavBottomBar extends StatelessWidget {
  const NavBottomBar({
    super.key,
    required this.currentIndex,
    required this.onSelect,
    this.onOpenSettings,
  });

  final int currentIndex;
  final ValueChanged<int> onSelect;

  /// Opens Settings in the reader's current destination.
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Tokens.pageMarginPhone,
        Tokens.s8,
        Tokens.pageMarginPhone,
        Tokens.s12,
      ),
      child: GlassSurface(
        shape: Tokens.shapePill,
        child: SizedBox(
          height: Tokens.navBarHeight,
          child: Row(
            children: <Widget>[
              for (final AppDestination destination in AppDestination.values)
                Expanded(
                  child: _NavBarItem(
                    destination: destination,
                    selected: AppDestination.values.indexOf(destination) ==
                        currentIndex,
                    onTap: () =>
                        onSelect(AppDestination.values.indexOf(destination)),
                  ),
                ),
              if (onOpenSettings != null) ...<Widget>[
                const SizedBox(
                  height: Tokens.s24,
                  child: VerticalDivider(width: Tokens.s8, color: Tokens.border),
                ),
                _NavAction(
                  icon: AppIcons.dotsThree,
                  label: 'Settings',
                  onTap: onOpenSettings!,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _NavAction extends StatelessWidget {
  const _NavAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: Tokens.minTouchTarget),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Tokens.s12),
            child: Icon(
              icon,
              size: Tokens.iconSize,
              color: Tokens.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _NavBarItem extends StatelessWidget {
  const _NavBarItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final AppDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color foreground = selected ? Tokens.accent : Tokens.textSecondary;

    return Semantics(
      button: true,
      selected: selected,
      label: destination.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: Tokens.minTouchTarget),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(
                selected ? destination.activeIcon : destination.icon,
                size: Tokens.iconSize,
                color: foreground,
              ),
              const SizedBox(height: Tokens.s4),
              Text(
                destination.label,
                style: Tokens.caption.copyWith(color: foreground),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
