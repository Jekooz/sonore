import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/icons.dart';
import '../theme/tokens.dart';
import 'glass_surface.dart';
import 'pressable.dart';

/// One action in a context menu.
///
/// Only actions the app can really perform are ever placed in a menu (spec
/// section 3.D: "Never display a menu item that is merely a placeholder").
/// Playlist renaming, editing and deletion have no endpoint in the sidecar, so
/// they are absent rather than disabled-and-decorative.
@immutable
class ContextMenuEntry {
  const ContextMenuEntry({
    required this.icon,
    required this.label,
    required this.onSelected,
    this.isDestructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onSelected;

  /// Destructive entries are tinted with the accent and confirm first; the
  /// caller supplies the confirmation.
  final bool isDestructive;
}

/// Menu width. Geometry rather than a spec token: the spec fixes the row height
/// and radius, not the width.
const double _menuWidth = 232;

/// Opens the shared context menu at [position] (a global offset).
///
/// The menu is glass (spec section 2: "Glass is for things that float above
/// content: … context menus"), with 44px rows and a 12px radius (section 3.J).
/// It closes on Escape, on a click outside, and on selecting an entry; Up/Down
/// and Enter drive it from the keyboard, and each entry is a labelled button
/// for screen readers.
Future<void> showContextMenu(
  BuildContext context, {
  required Offset position,
  required List<ContextMenuEntry> entries,
}) async {
  if (entries.isEmpty) return;
  await Navigator.of(context, rootNavigator: true).push<void>(
    _ContextMenuRoute(position: position, entries: entries),
  );
}

class _ContextMenuRoute extends PopupRoute<void> {
  _ContextMenuRoute({required this.position, required this.entries});

  final Offset position;
  final List<ContextMenuEntry> entries;

  @override
  Color? get barrierColor => Tokens.transparent;

  @override
  bool get barrierDismissible => true;

  @override
  String get barrierLabel => 'Context menu';

  @override
  Duration get transitionDuration => Tokens.dPress;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final Size screen = MediaQuery.sizeOf(context);
    // Keep the menu on screen when it is opened near an edge.
    final double left = position.dx.clamp(
      Tokens.s8,
      (screen.width - _menuWidth - Tokens.s8).clamp(Tokens.s8, screen.width),
    );
    final double estimatedHeight = entries.length * Tokens.menuRowHeight +
        Tokens.s16;
    final double top = position.dy.clamp(
      Tokens.s8,
      (screen.height - estimatedHeight - Tokens.s8)
          .clamp(Tokens.s8, screen.height),
    );

    return Stack(
      children: <Widget>[
        Positioned(
          left: left,
          top: top,
          child: _ContextMenu(entries: entries),
        ),
      ],
    );
  }
}

class _ContextMenu extends StatefulWidget {
  const _ContextMenu({required this.entries});

  final List<ContextMenuEntry> entries;

  @override
  State<_ContextMenu> createState() => _ContextMenuState();
}

class _ContextMenuState extends State<_ContextMenu> {
  int _highlighted = 0;

  void _activate(int index) {
    final ContextMenuEntry entry = widget.entries[index];
    Navigator.of(context).pop();
    entry.onSelected();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() =>
          _highlighted = (_highlighted + 1) % widget.entries.length);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() => _highlighted =
          (_highlighted - 1 + widget.entries.length) % widget.entries.length);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.space) {
      _activate(_highlighted);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Semantics(
        container: true,
        label: 'Context menu',
        child: SizedBox(
          width: _menuWidth,
          child: GlassSurface(
            radius: Tokens.rMenuItem,
            isStrong: true,
            // A menu is a functional surface; the specular streak belongs to
            // floating transport chrome, not to a list of actions.
            showSpecular: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Tokens.s8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (int i = 0; i < widget.entries.length; i++)
                    _ContextMenuRow(
                      entry: widget.entries[i],
                      highlighted: i == _highlighted,
                      onHover: () => setState(() => _highlighted = i),
                      onTap: () => _activate(i),
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

class _ContextMenuRow extends StatelessWidget {
  const _ContextMenuRow({
    required this.entry,
    required this.highlighted,
    required this.onHover,
    required this.onTap,
  });

  final ContextMenuEntry entry;
  final bool highlighted;
  final VoidCallback onHover;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color foreground =
        entry.isDestructive ? Tokens.accent : Tokens.text;

    return Semantics(
      button: true,
      label: entry.label,
      child: MouseRegion(
        onEnter: (_) => onHover(),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            height: Tokens.menuRowHeight,
            padding: const EdgeInsets.symmetric(horizontal: Tokens.s16),
            color: highlighted ? Tokens.surfaceRaised : Tokens.transparent,
            child: Row(
              children: <Widget>[
                Icon(entry.icon, size: Tokens.iconSize, color: foreground),
                const SizedBox(width: Tokens.s12),
                Expanded(
                  child: Text(
                    entry.label,
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
    );
  }
}

/// An overflow button that opens [entries] at its own position.
///
/// Used as a row's trailing affordance; the same menu opens on right-click or
/// long-press through [openMenuAt].
class ContextMenuButton extends StatelessWidget {
  const ContextMenuButton({
    super.key,
    required this.entries,
    this.semanticLabel = 'More actions',
  });

  final List<ContextMenuEntry> entries;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      semanticLabel: semanticLabel,
      onTap: () => showContextMenuAt(context, entries),
      child: const Icon(
        AppIcons.dotsThree,
        size: Tokens.iconSize,
        color: Tokens.textSecondary,
      ),
    );
  }
}

/// Opens [entries] anchored to the widget that was pressed.
Future<void> showContextMenuAt(
  BuildContext context,
  List<ContextMenuEntry> entries,
) {
  if (entries.isEmpty) return Future<void>.value();
  final RenderBox? box = context.findRenderObject() as RenderBox?;
  final Offset position = box == null
      ? Offset.zero
      : box.localToGlobal(box.size.center(Offset.zero));
  return showContextMenu(context, position: position, entries: entries);
}

/// Opens [entries] from a secondary (right-click / long-press) gesture.
Future<void> showContextMenuFromTap(
  BuildContext context,
  TapDownDetails details,
  List<ContextMenuEntry> entries,
) =>
    showContextMenu(context, position: details.globalPosition, entries: entries);
