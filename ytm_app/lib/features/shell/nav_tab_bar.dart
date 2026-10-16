import 'package:flutter/material.dart';

import '../../routing/destinations.dart';
import '../../theme/icons.dart';
import '../../theme/tokens.dart';
import '../../ui/glass_surface.dart';

/// The floating glass top tab bar.
///
/// Approved layout ("Navigation"): the left sidebar is gone. The four
/// destinations are tabs in one floating glass capsule and Settings is an icon
/// button at its right end. Active state is carried by [Tokens.accent] alone —
/// the tab the reader is on, or the Settings action when its own page (Settings
/// or the Equalizer) is the one on screen.
///
/// It is floating chrome, so it is built from [GlassSurface] — the single place
/// the app may blur — which is also what makes Reduce Transparency swap it for
/// the solid opaque fallback without any change here.
///
/// The active tab's own highlight is a raised pill, never a second color, and
/// it snaps instantly under Reduce Motion.
class NavTabBar extends StatelessWidget {
  const NavTabBar({
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
  /// the trailing action stands for.
  final bool settingsActive;

  /// Opens Settings in the reader's current destination.
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final bool reduceMotion = MediaQuery.of(context).disableAnimations;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Tokens.pageMarginDesktop,
        Tokens.s8,
        Tokens.pageMarginDesktop,
        Tokens.s8,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Tokens.tabBarMaxWidth),
          child: GlassSurface(
            shape: Tokens.shapePill,
            child: SizedBox(
              height: Tokens.tabBarHeight,
              child: Row(
                children: <Widget>[
                  const SizedBox(width: Tokens.s8),
                  for (final AppDestination destination in AppDestination.values)
                    Expanded(
                      child: _Tab(
                        destination: destination,
                        selected: !settingsActive &&
                            AppDestination.values.indexOf(destination) ==
                                currentIndex,
                        reduceMotion: reduceMotion,
                        onTap: () => onSelect(
                          AppDestination.values.indexOf(destination),
                        ),
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
                    _SettingsAction(
                      selected: settingsActive,
                      reduceMotion: reduceMotion,
                      onTap: onOpenSettings!,
                    ),
                  ],
                  const SizedBox(width: Tokens.s8),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One destination tab: glyph (filled while active), label, and the accent on
/// the active state only.
class _Tab extends StatelessWidget {
  const _Tab({
    required this.destination,
    required this.selected,
    required this.reduceMotion,
    required this.onTap,
  });

  final AppDestination destination;
  final bool selected;
  final bool reduceMotion;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color foreground = selected ? Tokens.accent : Tokens.textSecondary;

    return Semantics(
      button: true,
      selected: selected,
      label: destination.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Tokens.s4,
              vertical: Tokens.s8,
            ),
            child: AnimatedContainer(
              duration: reduceMotion ? Duration.zero : Tokens.dPress,
              curve: Tokens.curvePress,
              alignment: Alignment.center,
              decoration: ShapeDecoration(
                color: selected ? Tokens.surfaceRaised : Tokens.transparent,
                shape: Tokens.shapePill,
              ),
              child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      selected ? destination.activeIcon : destination.icon,
                      size: Tokens.iconSize,
                      color: foreground,
                    ),
                    const SizedBox(width: Tokens.s8),
                    Flexible(
                      child: Text(
                        destination.label,
                        style: Tokens.rowTitle.copyWith(color: foreground),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
    );
  }
}

/// The trailing Settings action. It is not a destination: it pushes a page on
/// top of the current branch, so exactly one of the four tabs stays lit while
/// the reader browses, and Settings lights only when one of its own pages is.
class _SettingsAction extends StatelessWidget {
  const _SettingsAction({
    required this.selected,
    required this.reduceMotion,
    required this.onTap,
  });

  final bool selected;
  final bool reduceMotion;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color foreground = selected ? Tokens.accent : Tokens.textSecondary;

    return Semantics(
      button: true,
      selected: selected,
      label: 'Settings',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox(
            width: Tokens.minTouchTarget,
            height: Tokens.tabBarHeight,
            child: Center(
              child: AnimatedContainer(
                duration: reduceMotion ? Duration.zero : Tokens.dPress,
                curve: Tokens.curvePress,
                width: Tokens.s32 + Tokens.s4,
                height: Tokens.s32 + Tokens.s4,
                alignment: Alignment.center,
                decoration: ShapeDecoration(
                  color: selected ? Tokens.surfaceRaised : Tokens.transparent,
                  shape: Tokens.shapePill,
                ),
                child: Icon(
                  AppIcons.dotsThree,
                  size: Tokens.iconSize,
                  color: foreground,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
