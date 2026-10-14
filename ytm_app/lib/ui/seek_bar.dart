import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The progress control from the spec's `lib/ui/` list.
///
/// It is a real interactive control, not just an indicator:
/// tapping or clicking seeks, dragging shows a temporary preview and commits
/// exactly one seek on release, and the bar thickens from 4 to 8 px on touch or
/// hover. Played and buffered progress are drawn separately.
///
/// When the duration is unknown or the stream cannot seek, pass
/// [enabled] = false: the bar renders inert instead of pretending the action
/// worked. The invisible hit area is [Tokens.minTouchTarget] tall.
class SeekBar extends StatefulWidget {
  const SeekBar({
    super.key,
    required this.position,
    required this.duration,
    this.buffered = Duration.zero,
    this.enabled = true,
    this.onSeekStart,
    this.onSeek,
    this.onSeekEnd,
  });

  final Duration position;
  final Duration duration;
  final Duration buffered;
  final bool enabled;

  /// Called once when a drag or tap begins, with the previewed position.
  final ValueChanged<Duration>? onSeekStart;

  /// Called continuously while dragging, with the previewed position.
  final ValueChanged<Duration>? onSeek;

  /// Called once on release, with the committed position.
  final ValueChanged<Duration>? onSeekEnd;

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? _preview;
  bool _hovered = false;

  int get _totalMs => widget.duration.inMilliseconds;

  bool get _interactive =>
      widget.enabled && _totalMs > 0 && widget.onSeekEnd != null;

  Duration _at(double fraction) =>
      Duration(milliseconds: (fraction * _totalMs).round());

  double _fractionOf(double dx, double width) =>
      width <= 0 ? 0 : (dx / width).clamp(0.0, 1.0);

  void _beginPreview(double fraction) {
    setState(() => _preview = fraction);
    widget.onSeekStart?.call(_at(fraction));
  }

  void _updatePreview(double fraction) {
    setState(() => _preview = fraction);
    widget.onSeek?.call(_at(fraction));
  }

  void _commit(double? fraction) {
    setState(() => _preview = null);
    if (fraction != null) widget.onSeekEnd?.call(_at(fraction));
  }

  @override
  Widget build(BuildContext context) {
    final double thickness = (_hovered || _preview != null)
        ? Tokens.seekBarThicknessActive
        : Tokens.seekBarThickness;

    final double played = _preview ??
        (_totalMs == 0 ? 0 : (widget.position.inMilliseconds / _totalMs).clamp(0.0, 1.0));
    final double buffered =
        _totalMs == 0 ? 0 : (widget.buffered.inMilliseconds / _totalMs).clamp(0.0, 1.0);

    final Color remainingColor =
        _interactive ? Tokens.surfaceRaised : Tokens.surface;
    final Color bufferedColor =
        _interactive ? Tokens.textMuted : Tokens.surfaceRaised;
    final Color playedColor = _interactive ? Tokens.accent : Tokens.border;

    return MouseRegion(
      cursor: _interactive ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: Tokens.minTouchTarget),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final double width = constraints.maxWidth;

            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: _interactive
                  ? (TapDownDetails d) =>
                      _beginPreview(_fractionOf(d.localPosition.dx, width))
                  : null,
              onTapUp: _interactive
                  ? (TapUpDetails d) =>
                      _commit(_fractionOf(d.localPosition.dx, width))
                  : null,
              onTapCancel: _interactive ? () => _commit(null) : null,
              onHorizontalDragStart: _interactive
                  ? (DragStartDetails d) =>
                      _beginPreview(_fractionOf(d.localPosition.dx, width))
                  : null,
              onHorizontalDragUpdate: _interactive
                  ? (DragUpdateDetails d) =>
                      _updatePreview(_fractionOf(d.localPosition.dx, width))
                  : null,
              onHorizontalDragEnd: _interactive
                  ? (DragEndDetails _) => _commit(_preview)
                  : null,
              child: Center(
                child: AnimatedContainer(
                  duration: Tokens.dPress,
                  curve: Tokens.curvePress,
                  height: thickness,
                  child: Stack(
                    alignment: AlignmentDirectional.centerStart,
                    children: <Widget>[
                      _segment(1, remainingColor),
                      _segment(buffered, bufferedColor),
                      _segment(played, playedColor),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _segment(double factor, Color color) {
    return FractionallySizedBox(
      widthFactor: factor.clamp(0.0, 1.0),
      alignment: AlignmentDirectional.centerStart,
      child: DecoratedBox(
        decoration: ShapeDecoration(color: color, shape: Tokens.shapePill),
        child: const SizedBox.expand(),
      ),
    );
  }
}
