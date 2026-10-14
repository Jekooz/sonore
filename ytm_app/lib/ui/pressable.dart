import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Press feedback from the spec: scale to 0.97 in 80 ms, release with a spring.
///
/// All motion is interruptible; with Reduce Motion on the scale is skipped
/// entirely. The hit area is never smaller than [Tokens.minTouchTarget].
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.enabled = true,
    this.semanticLabel,
  });

  final Widget child;
  final VoidCallback? onTap;
  final bool enabled;
  final String? semanticLabel;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _pressed = false;

  bool get _reduceMotion =>
      MediaQuery.of(context).disableAnimations;

  void _setPressed(bool value) {
    if (widget.onTap == null || !widget.enabled) return;
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final bool canTap = widget.enabled && widget.onTap != null;
    final double scale = _pressed && !_reduceMotion ? Tokens.pressScale : 1;

    return Semantics(
      button: canTap,
      enabled: widget.enabled,
      label: widget.semanticLabel,
      child: MouseRegion(
        cursor: canTap ? SystemMouseCursors.click : MouseCursor.defer,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => _setPressed(true),
          onTapUp: (_) => _setPressed(false),
          onTapCancel: () => _setPressed(false),
          onTap: canTap ? widget.onTap : null,
          child: AnimatedScale(
            scale: scale,
            duration: Tokens.dPress,
            curve: _pressed ? Tokens.curvePress : Tokens.curveRelease,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minWidth: Tokens.minTouchTarget,
                minHeight: Tokens.minTouchTarget,
              ),
              child: Center(child: widget.child),
            ),
          ),
        ),
      ),
    );
  }
}
