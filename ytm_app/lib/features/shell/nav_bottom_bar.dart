import 'package:flutter/material.dart';

import '../../routing/destinations.dart';
import '../../theme/icons.dart';
import '../../theme/tokens.dart';
import '../../ui/glass_surface.dart';

/// Phone navigation.
///
/// Spec: "Phone: glass bottom bar (pill, active icon filled and accented) with
/// the Now Playing bar docked just above it." Touch targets stay at or above
/// [Tokens.minTouchTarget]. Under the glass direction the accent is white on
/// the pill's raised tint instead of a hue.
///
/// Settings is a trailing action rather than a fifth destination: the spec
/// keeps four destinations but lists Settings in the navigation menu, so it
/// gets its own divided slot instead of changing what a tab is.
class NavBottomBar extends StatelessWidget {
  const NavBottomBar({
    super.key,
    required this.currentIndex,
    required this.onSelect,
    this.settingsActive = false,
    this.onOpenSettings,
  });

  /// Index of the highlighted destination, or null when a Settings page is on
  /// screen and no destination should be highlighted.
  final int? currentIndex;
  final ValueChanged<int> onSelect;

  /// True while the page on screen is Settings or the Equalizer, which is what
  /// the Settings item stands for.
  final bool settingsActive;

  /// Opens Settings in the reader's current destination.
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    // The highlight follows the route: on Settings and the Equalizer the
    // Settings action is the active one, so the destination behind it is not
    // left lit.
    final int? highlighted = settingsActive ? null : currentIndex;

    // Narrow phone windows swap "Now Playing" for "Playing" — the ink of the
    // long label cannot fit four destinations plus the settings slot without
    // clipping, and its ellipsis would make the selected tab unreadable.
    final bool narrow = MediaQuery.sizeOf(context).width <= 400;

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
          // The inset keeps the selected pill off the bar's own edge at the
          // narrowest phone widths — a pill kissing the glass rim reads as a
          // rendering error, and the row here has nothing else breathing in.
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Tokens.s8),
            child: Row(
              children: <Widget>[
                for (final AppDestination destination in AppDestination.values)
                  Expanded(
                    child: _NavBarItem(
                      destination: destination,
                      selected:
                          AppDestination.values.indexOf(destination) ==
                          highlighted,
                      narrow: narrow,
                      onTap: () =>
                          onSelect(AppDestination.values.indexOf(destination)),
                    ),
                  ),
                if (onOpenSettings != null) ...<Widget>[
                  const SizedBox(
                    height: Tokens.s24,
                    child: VerticalDivider(
                      width: Tokens.s8,
                      color: Tokens.border,
                    ),
                  ),
                  _NavAction(
                    icon: AppIcons.dotsThree,
                    label: 'Settings',
                    selected: settingsActive,
                    onTap: onOpenSettings!,
                  ),
                ],
              ],
            ),
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
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// True while this action's own page is the one on screen.
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final bool reduceMotion = MediaQuery.of(context).disableAnimations;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: Tokens.navPillRadius,
            hoverColor: Tokens.glassThick,
            focusColor: Tokens.glassThick,
            splashColor: Tokens.transparent,
            child: Padding(
              // The dots need a real target: horizontal padding makes the
              // ~24dp icon 48dp wide, vertical padding makes it 48dp tall —
              // an overflow action with no breathing room is exactly the hit
              // that gets missed.
              padding: const EdgeInsets.symmetric(
                vertical: Tokens.s12,
                horizontal: Tokens.s12,
              ),
              child: AnimatedContainer(
                duration: reduceMotion ? Duration.zero : Tokens.dPress,
                curve: Tokens.curvePress,
                decoration: selected
                    ? navSelectionDecoration(Tokens.shapePill)
                    : null,
                child: Icon(
                  icon,
                  size: Tokens.iconSize,
                  color: selected ? Tokens.text : Tokens.textSecondary,
                ),
              ),
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
    required this.narrow,
  });

  final AppDestination destination;
  final bool selected;
  final VoidCallback onTap;

  /// The narrowest phone layout: labels use the destination's short form so
  /// four destinations plus the settings slot always fit on one line.
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    final Color foreground = selected ? Tokens.text : Tokens.textSecondary;
    final bool reduceMotion = MediaQuery.of(context).disableAnimations;

    return Semantics(
      button: true,
      selected: selected,
      label: destination.label,
      child: Tooltip(
        message: destination.label,
        excludeFromSemantics: true,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: Tokens.navPillRadius,
            hoverColor: Tokens.glassThick,
            focusColor: Tokens.glassThick,
            splashColor: Tokens.transparent,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Tokens.s4),
              child: AnimatedContainer(
                duration: reduceMotion ? Duration.zero : Tokens.dPress,
                curve: Tokens.curvePress,
                decoration: selected
                    ? navSelectionDecoration(Tokens.shapePill)
                    : null,
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
                      // Visible label shortens on the narrowest phones; the
                      // tooltip and the semantics keep the full name.
                      narrow ? destination.shortLabel : destination.label,
                      style: Tokens.caption.copyWith(color: foreground),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
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
