import 'package:flutter/material.dart';

import '../../theme/icons.dart';
import '../../theme/tokens.dart';
import '../../ui/context_menu.dart';

/// The custom Windows title bar.
///
/// It is deliberately pure: the window operations arrive as callbacks, so the
/// widget can be rendered and golden-tested without a platform channel. The app
/// wires the callbacks to `window_manager` in `main.dart`; tests pass
/// callbacks that record the call.
///
/// The maximize button also carries the app's own snap menu (right-click /
/// long-press): the OS Snap-layouts flyout cannot appear over a custom title
/// bar, so the halves it would offer are offered here instead, delegated to
/// [onSnapLeft]/[onSnapRight].
class WindowTitleBar extends StatelessWidget {
  const WindowTitleBar({
    super.key,
    required this.title,
    this.onDragStart,
    this.onMinimize,
    this.onMaximizeToggle,
    this.onClose,
    this.onSnapLeft,
    this.onSnapRight,
    this.isMaximized = false,
  });

  final String title;
  final VoidCallback? onDragStart;
  final VoidCallback? onMinimize;
  final VoidCallback? onMaximizeToggle;
  final VoidCallback? onClose;
  final VoidCallback? onSnapLeft;
  final VoidCallback? onSnapRight;
  final bool isMaximized;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: Tokens.titleBarHeight,
      child: Row(
        children: <Widget>[
          const SizedBox(width: Tokens.s12),
          Text(title, style: Tokens.caption),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => onDragStart?.call(),
              onDoubleTap: onMaximizeToggle,
            ),
          ),
          _CaptionButton(
            icon: AppIcons.minimize,
            semanticLabel: 'Minimize',
            onPressed: onMinimize,
          ),
          if (onSnapLeft != null && onSnapRight != null)
            _CaptionButton(
              icon: isMaximized ? AppIcons.restore : AppIcons.maximize,
              semanticLabel: isMaximized ? 'Restore' : 'Maximize',
              onPressed: onMaximizeToggle,
              onSecondaryTap: () => _openSnapMenu(context),
            )
          else
            _CaptionButton(
              icon: isMaximized ? AppIcons.restore : AppIcons.maximize,
              semanticLabel: isMaximized ? 'Restore' : 'Maximize',
              onPressed: onMaximizeToggle,
            ),
          _CaptionButton(
            icon: AppIcons.close,
            semanticLabel: 'Close',
            onPressed: onClose,
          ),
        ],
      ),
    );
  }

  /// The snap menu in the glass context menu itself, so keyboard navigation
  /// and Escape-to-close come for free.
  void _openSnapMenu(BuildContext context) {
    showContextMenuAt(context, <ContextMenuEntry>[
      ContextMenuEntry(
        icon: AppIcons.caretLeft,
        label: 'Snap left',
        onSelected: () => onSnapLeft!(),
      ),
      ContextMenuEntry(
        icon: AppIcons.caretRight,
        label: 'Snap right',
        onSelected: () => onSnapRight!(),
      ),
      ContextMenuEntry(
        icon: isMaximized ? AppIcons.restore : AppIcons.maximize,
        label: isMaximized ? 'Restore' : 'Maximize',
        onSelected: onMaximizeToggle!,
      ),
    ]);
  }
}

class _CaptionButton extends StatelessWidget {
  const _CaptionButton({
    required this.icon,
    required this.semanticLabel,
    this.onPressed,
    this.onSecondaryTap,
  });

  final IconData icon;
  final String semanticLabel;
  final VoidCallback? onPressed;
  final VoidCallback? onSecondaryTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: Tokens.captionButtonWidth,
      height: Tokens.titleBarHeight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        onSecondaryTap: onSecondaryTap,
        onLongPress: onSecondaryTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Icon(icon, size: Tokens.iconSize, color: Tokens.textSecondary),
        ),
      ),
    );
  }
}
