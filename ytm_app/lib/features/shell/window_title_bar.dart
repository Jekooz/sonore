import 'package:flutter/material.dart';

import '../../theme/icons.dart';
import '../../theme/tokens.dart';

/// The custom Windows title bar.
///
/// It is deliberately pure: the window operations arrive as callbacks, so the
/// widget can be rendered and golden-tested without a platform channel. The app
/// wires the callbacks to `window_manager` in `main.dart`; tests pass
/// callbacks that record the call.
class WindowTitleBar extends StatelessWidget {
  const WindowTitleBar({
    super.key,
    required this.title,
    this.onDragStart,
    this.onMinimize,
    this.onMaximizeToggle,
    this.onClose,
    this.isMaximized = false,
  });

  final String title;
  final VoidCallback? onDragStart;
  final VoidCallback? onMinimize;
  final VoidCallback? onMaximizeToggle;
  final VoidCallback? onClose;
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
}

class _CaptionButton extends StatelessWidget {
  const _CaptionButton({
    required this.icon,
    required this.semanticLabel,
    this.onPressed,
  });

  final IconData icon;
  final String semanticLabel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: Tokens.captionButtonWidth,
      height: Tokens.titleBarHeight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Icon(icon, size: Tokens.iconSize, color: Tokens.textSecondary),
        ),
      ),
    );
  }
}
