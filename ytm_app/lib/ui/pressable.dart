import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';

/// Press feedback from the spec: scale to 0.97 in 80 ms, release with a spring.
///
/// All motion is interruptible; with Reduce Motion on the scale is skipped
/// entirely. The hit area is never smaller than [Tokens.minTouchTarget].
///
/// Every [Pressable] is also a real keyboard control: it takes focus by tab,
/// answers to Enter and Space, and shows a visible focus ring — only while
/// the focus came from the keyboard, so pointer users never see it flash.
/// This is what makes every row, pill and icon button reachable without a
/// mouse (spec: "full tab/arrow nav, visible focus rings").
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.enabled = true,
    this.semanticLabel,
    this.focusNode,
    this.autofocus = false,
  });

  final Widget child;
  final VoidCallback? onTap;
  final bool enabled;
  final String? semanticLabel;

  /// An externally owned [FocusNode], so a screen can hand focus to a control
  /// from a shortcut or a state change.
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _pressed = false;
  bool _focusVisible = false;

  bool get _reduceMotion => MediaQuery.of(context).disableAnimations;

  bool get _canActivate => widget.enabled && widget.onTap != null;

  void _setPressed(bool value) {
    if (!_canActivate) return;
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  void _activate() {
    if (!_canActivate) return;
    widget.onTap!();
  }

  @override
  Widget build(BuildContext context) {
    final double scale = _pressed && !_reduceMotion ? Tokens.pressScale : 1;

    return Semantics(
      button: _canActivate,
      enabled: widget.enabled,
      label: widget.semanticLabel,
      child: FocusableActionDetector(
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        enabled: _canActivate,
        mouseCursor: _canActivate
            ? SystemMouseCursors.click
            : MouseCursor.defer,
        onFocusChange: (bool focused) {
          if (!focused && _pressed && mounted) _setPressed(false);
        },
        // The ring marks keyboard focus specifically: after a click the
        // highlight stays off, matching every desktop platform.
        onShowFocusHighlight: (bool visible) {
          if (visible != _focusVisible) setState(() => _focusVisible = visible);
        },
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (ActivateIntent intent) {
              _activate();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => _setPressed(true),
          onTapUp: (_) => _setPressed(false),
          onTapCancel: () => _setPressed(false),
          onTap: _canActivate ? widget.onTap : null,
          child: AnimatedScale(
            scale: scale,
            duration: Tokens.dPress,
            curve: _pressed ? Tokens.curvePress : Tokens.curveRelease,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minWidth: Tokens.minTouchTarget,
                minHeight: Tokens.minTouchTarget,
              ),
              // Factors of 1 shrink-wrap to the child instead of expanding to
              // whatever width the parent offers. Without them a pressable took
              // the full width it was handed and centred its child inside, so a
              // pill in a Wrap occupied a row of its own and a button in a
              // stretched column was centred rather than starting at the left
              // edge. A child that genuinely wants the whole width (a full-width
              // row, a stretched box) still gets it. The 48x48 minimum above
              // keeps the touch target intact either way.
              child: Align(
                alignment: Alignment.center,
                widthFactor: 1,
                heightFactor: 1,
                child: _FocusRing(
                  visible: _focusVisible,
                  child: widget.child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The visible keyboard-focus ring, drawn just outside the control's bounds
/// without shifting any layout.
class _FocusRing extends StatelessWidget {
  const _FocusRing({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!visible) {
      return Stack(
        clipBehavior: Clip.none,
        children: <Widget>[child],
      );
    }
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        child,
        Positioned.fill(
          left: -Tokens.focusRingWidth,
          top: -Tokens.focusRingWidth,
          right: -Tokens.focusRingWidth,
          bottom: -Tokens.focusRingWidth,
          child: IgnorePointer(
            child: CustomPaint(
              size: Size.infinite,
              painter: _RingPainter(),
            ),
          ),
        ),
      ],
    );
  }
}

class _RingPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final double half = Tokens.focusRingWidth / 2;
    final RRect rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        -half,
        -half,
        size.width + Tokens.focusRingWidth,
        size.height + Tokens.focusRingWidth,
      ),
      Radius.circular(Tokens.rSmall),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = Tokens.focusRing
        ..style = PaintingStyle.stroke
        ..strokeWidth = Tokens.focusRingWidth,
    );
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) => false;
}
