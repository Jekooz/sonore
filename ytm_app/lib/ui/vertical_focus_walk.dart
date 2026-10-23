import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Arrow-key row walking for full-width result lists (search, queue).
///
/// The widget sits *around* a row and observes the key events its focused
/// control bubbles up: ArrowDown / ArrowUp delegate to the enclosing
/// [FocusTraversalGroup]'s policy, so focus follows the visual row order
/// without every screen re-implementing focus bookkeeping. The group must be
/// an ancestor (the screen wraps its content in one horizontal group).
///
/// This is the piece that makes search results keyboard-selectable: Tab
/// reaches the field and rows, and the arrows walk them like a real list.
class VerticalFocusWalk extends StatelessWidget {
  const VerticalFocusWalk({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    KeyEventResult onKeyEvent(FocusNode node, KeyEvent event) {
      if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
        return KeyEventResult.ignored;
      }
      final TraversalDirection? direction = switch (event.logicalKey) {
        LogicalKeyboardKey.arrowDown => TraversalDirection.down,
        LogicalKeyboardKey.arrowUp => TraversalDirection.up,
        _ => null,
      };
      if (direction == null) return KeyEventResult.ignored;
      final FocusTraversalPolicy? policy = FocusTraversalGroup.maybeOf(context);
      if (policy == null) return KeyEventResult.ignored;
      if (policy.inDirection(node, direction)) {
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    return Focus(
      // Never a stop itself: it only hears events that a focused descendant
      // did not already handle.
      canRequestFocus: false,
      onKeyEvent: onKeyEvent,
      child: child,
    );
  }
}
