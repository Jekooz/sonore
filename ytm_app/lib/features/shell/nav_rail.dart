import 'package:flutter/material.dart';

import '../../routing/destinations.dart';
import '../../theme/icons.dart';
import '../../theme/tokens.dart';

/// Desktop navigation.
///
/// Spec: "220px glass sidebar, collapsing to a 72px icon rail below that."
/// The sidebar is a flat [Tokens.surface] panel rather than a glass surface:
/// spec principle 3 reserves glass for floating chrome (mini player, transport
/// pill, top bar, bottom nav, sheets), and the sidebar is fixed, not floating.
///
/// Settings sits below the four destinations, separated, because the spec puts
/// it in the navigation menu while keeping exactly four destinations.
class NavRail extends StatelessWidget {
  const NavRail({
    super.key,
    required this.currentIndex,
    required this.onSelect,
    required this.expanded,
    this.onOpenSettings,
  });

  final int currentIndex;
  final ValueChanged<int> onSelect;

  /// True at 900px and wider: icons plus labels. False: icons only.
  final bool expanded;

  /// Opens Settings in the reader's current destination.
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(Tokens.s12),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: Tokens.surface,
          shape: Tokens.shapeFor(Tokens.rCard),
        ),
        child: SizedBox(
          width: expanded ? Tokens.sidebarWidth : Tokens.sidebarRailWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const SizedBox(height: Tokens.s12),
              for (final AppDestination destination in AppDestination.values)
                _NavRailItem(
                  destination: destination,
                  expanded: expanded,
                  selected: AppDestination.values.indexOf(destination) ==
                      currentIndex,
                  onTap: () => onSelect(
                    AppDestination.values.indexOf(destination),
                  ),
                ),
              const Spacer(),
              if (onOpenSettings != null)
                _NavRailAction(
                  icon: AppIcons.dotsThree,
                  label: 'Settings',
                  expanded: expanded,
                  onTap: onOpenSettings!,
                ),
              const SizedBox(height: Tokens.s8),
            ],
          ),
        ),
      ),
    );
  }
}

/// A navigation action that is not a destination: it pushes a page on top of
/// the branch rather than switching branch, so the four destinations keep
/// their own state and their own highlight.
class _NavRailAction extends StatefulWidget {
  const _NavRailAction({
    required this.icon,
    required this.label,
    required this.expanded,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool expanded;
  final VoidCallback onTap;

  @override
  State<_NavRailAction> createState() => _NavRailActionState();
}

class _NavRailActionState extends State<_NavRailAction> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: Tokens.dPress,
            curve: Tokens.curvePress,
            constraints: const BoxConstraints(minHeight: Tokens.minTouchTarget),
            margin: const EdgeInsets.symmetric(
              horizontal: Tokens.s8,
              vertical: Tokens.s4,
            ),
            padding: const EdgeInsets.symmetric(horizontal: Tokens.s12),
            decoration: ShapeDecoration(
              color: _hovered ? Tokens.surfaceRaised : Tokens.transparent,
              shape: Tokens.shapeFor(Tokens.rSmall),
            ),
            child: Row(
              mainAxisAlignment: widget.expanded
                  ? MainAxisAlignment.start
                  : MainAxisAlignment.center,
              children: <Widget>[
                Icon(
                  widget.icon,
                  size: Tokens.iconSize,
                  color: Tokens.textSecondary,
                ),
                if (widget.expanded) ...<Widget>[
                  const SizedBox(width: Tokens.s12),
                  Flexible(
                    child: Text(
                      widget.label,
                      style: Tokens.rowTitle.copyWith(
                        color: Tokens.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
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

class _NavRailItem extends StatefulWidget {
  const _NavRailItem({
    required this.destination,
    required this.expanded,
    required this.selected,
    required this.onTap,
  });

  final AppDestination destination;
  final bool expanded;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_NavRailItem> createState() => _NavRailItemState();
}

class _NavRailItemState extends State<_NavRailItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final Color foreground =
        widget.selected ? Tokens.accent : Tokens.textSecondary;

    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.destination.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: Tokens.dPress,
            curve: Tokens.curvePress,
            constraints: const BoxConstraints(minHeight: Tokens.minTouchTarget),
            margin: const EdgeInsets.symmetric(
              horizontal: Tokens.s8,
              vertical: Tokens.s4,
            ),
            padding: const EdgeInsets.symmetric(horizontal: Tokens.s12),
            decoration: ShapeDecoration(
              color: _hovered ? Tokens.surfaceRaised : Tokens.transparent,
              shape: Tokens.shapeFor(Tokens.rSmall),
            ),
            child: Row(
              mainAxisAlignment: widget.expanded
                  ? MainAxisAlignment.start
                  : MainAxisAlignment.center,
              children: <Widget>[
                Icon(
                  widget.selected
                      ? widget.destination.activeIcon
                      : widget.destination.icon,
                  size: Tokens.iconSize,
                  color: foreground,
                ),
                if (widget.expanded) ...<Widget>[
                  const SizedBox(width: Tokens.s12),
                  Flexible(
                    child: Text(
                      widget.destination.label,
                      style: Tokens.rowTitle.copyWith(color: foreground),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
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
