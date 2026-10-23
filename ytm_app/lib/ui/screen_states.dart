import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'pill_button.dart';

/// A shimmering placeholder shown while a screen is loading.
///
/// The shimmer sweeps once per [Tokens.dShimmer]. With Reduce Motion on it
/// renders as a static raised block instead of animating.
class Skeleton extends StatefulWidget {
  const Skeleton({
    super.key,
    this.width,
    this.height = Tokens.s16,
    this.radius = Tokens.rSmall,
  });

  final double? width;
  final double height;
  final double radius;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: Tokens.dShimmer,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final OutlinedBorder shape = Tokens.shapeFor(widget.radius);

    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: MediaQuery.of(context).disableAnimations
          ? DecoratedBox(
              decoration: ShapeDecoration(
                color: Tokens.surfaceRaised,
                shape: shape,
              ),
            )
          : AnimatedBuilder(
              animation: _controller,
              builder: (BuildContext context, Widget? child) {
                // Sweep geometry, not a design value: the gradient highlight
                // travels from one edge to the other over the shimmer period.
                final double slide = _controller.value * 2 - 1;
                return DecoratedBox(
                  decoration: ShapeDecoration(
                    shape: shape,
                    gradient: LinearGradient(
                      begin: Alignment(-1 + slide, 0),
                      end: Alignment(1 + slide, 0),
                      colors: const <Color>[
                        Tokens.surfaceRaised,
                        Tokens.surface,
                        Tokens.surfaceRaised,
                      ],
                      stops: const <double>[0.3, 0.5, 0.7],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

/// The empty / error / offline presentation: one sentence, an optional
/// explanation, and the actions a user can take.
///
/// [actionLabel] is the state's real action and is drawn as a filled button;
/// [secondaryLabel] is for the side step a state also needs (opening a folder,
/// for instance) and is drawn as a quieter text button beside it.
///
/// Error states use neutral text rather than red (spec: "error ... no red").
class StateMessage extends StatelessWidget {
  const StateMessage({
    super.key,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.actionIcon,
    this.footnote,
    this.secondaryLabel,
    this.onSecondary,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final IconData? actionIcon;
  final String? footnote;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    return Center(
      // Keep a readable measure: the message and its footnote wrap inside the
      // same narrow column every other form on the app uses, instead of
      // running corner to corner on a wide window.
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: Tokens.formMaxWidth),
        child: Padding(
          padding: const EdgeInsets.all(Tokens.s24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                message,
                style: Tokens.rowTitle,
                textAlign: TextAlign.center,
              ),
              if (footnote != null) ...<Widget>[
                const SizedBox(height: Tokens.s8),
                Text(
                  footnote!,
                  style: Tokens.subtitle,
                  textAlign: TextAlign.center,
                ),
              ],
              if (actionLabel != null && onAction != null) ...<Widget>[
                const SizedBox(height: Tokens.s24),
                PillButton(
                  icon: actionIcon,
                  label: actionLabel,
                  onPressed: onAction,
                ),
              ],
              if (secondaryLabel != null && onSecondary != null) ...<Widget>[
                const SizedBox(height: Tokens.s4),
                TextButton(
                  onPressed: onSecondary,
                  child: Text(secondaryLabel!, style: Tokens.subtitle),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
