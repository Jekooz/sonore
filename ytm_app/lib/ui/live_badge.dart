import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'ambient/ambient_backdrop.dart';

/// The "Now Playing" mark: three bars that dance while audio is playing and
/// settle to a static silhouette when it is not.
///
/// Decoration only — it is hidden from semantics, because the row itself
/// already announces the playing state through its selected flags. Motion
/// respects the shared test gate ([ambientMotionEnabled]), Reduce Motion and
/// the paused state; a settled tree never has live tickers in it, so
/// `pumpAndSettle` stays honest everywhere the badge is shown.
class LiveBadge extends StatefulWidget {
  const LiveBadge({super.key, required this.isPlaying});

  final bool isPlaying;

  @override
  State<LiveBadge> createState() => _LiveBadgeState();
}

class _LiveBadgeState extends State<LiveBadge>
    with SingleTickerProviderStateMixin {
  /// One controller drives all three bars; each bar reads its own phase from
  /// the shared value, so the trio reads as rhythm, not one pulsing block.
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: Tokens.dShimmer);

  static const int _count = 3;

  static const double _gap = Tokens.liveBadgeGap;
  static const double _barWidth = Tokens.liveBadgeBarWidth;

  /// total footprint, including every trailing gap.
  static const double _width = _count * (_barWidth + _gap);

  /// Resting heights for the static silhouette.
  static const List<double> _rest = <double>[4, 8, 12];

  bool _moving = false;

  @override
  void initState() {
    super.initState();
    // MediaQuery is safe on the first frame after layout.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncMotion();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  @override
  void didUpdateWidget(LiveBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying) _syncMotion();
  }

  void _syncMotion() {
    final bool wanted =
        widget.isPlaying && ambientMotionEnabled && !_reduced(context);
    if (wanted == _moving) return;
    setState(() => _moving = wanted);
    if (wanted) {
      _controller.repeat(reverse: true, period: Tokens.dShimmer);
    } else {
      _controller.stop();
    }
  }

  static bool _reduced(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool moving =
        widget.isPlaying && ambientMotionEnabled && !_reduced(context);

    Widget bars(double Function(int index) heightFor) {
      return SizedBox(
        width: _width,
        height: Tokens.s16 + 12,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            for (int i = 0; i < _count; i++)
              Container(
                width: _barWidth,
                height: heightFor(i),
                margin: const EdgeInsets.only(right: _gap),
                decoration: ShapeDecoration(
                  color: Tokens.text,
                  shape: Tokens.shapePill,
                ),
              ),
          ],
        ),
      );
    }

    if (!moving) {
      // Paused, reduce-motion, or the test gate: a static silhouette with no
      // ticker attached at all.
      return bars((int i) => _rest[i]);
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? _) {
        return bars((int i) {
          // Three phases sampled at thirds of the cycle, with an eased
          // 0.35→1 envelope so the bars swing rather than blink.
          final double phase = _controller.value + i / _count;
          final double wiggle = 0.65 + 0.35 * math.sin(phase * 2 * math.pi);
          return (Tokens.s16 * wiggle).clamp(Tokens.s4, Tokens.s16);
        });
      },
    );
  }
}
