import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'format.dart';
import 'glass_surface.dart';

/// The progress control from the spec's `lib/ui/` list.
///
/// It is a real interactive control, not just an indicator:
/// tapping or clicking seeks, dragging shows a temporary preview and commits
/// exactly one seek on release, and the bar thickens under touch or hover
/// while a round thumb grows out of the track. Played and buffered progress
/// are drawn separately.
///
/// When the duration is unknown or the stream cannot seek, pass
/// [enabled] = false: the bar renders inert instead of pretending the action
/// worked. The invisible hit area is [Tokens.minTouchTarget] tall, or
/// [Tokens.seekHitHeightCompact] in [compact] mode.
class SeekBar extends StatefulWidget {
  const SeekBar({
    super.key,
    required this.position,
    required this.duration,
    this.buffered = Duration.zero,
    this.enabled = true,
    this.compact = false,
    this.onSeekStart,
    this.onSeek,
    this.onSeekEnd,
  });

  final Duration position;
  final Duration duration;
  final Duration buffered;
  final bool enabled;

  /// The hairline variant used where a full-height scrubber would crowd the
  /// layout — the floating Now Playing bar. Same behaviours, smaller geometry,
  /// all of it from tokens.
  final bool compact;

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

  bool get _compact => widget.compact;

  double get _thickness =>
      (_hovered || _preview != null)
      ? (_compact
            ? Tokens.seekBarThicknessCompactActive
            : Tokens.seekBarThicknessActive)
      : (_compact
            ? Tokens.seekBarThicknessCompact
            : Tokens.seekBarThickness);

  double get _hitHeight =>
      _compact ? Tokens.seekHitHeightCompact : Tokens.minTouchTarget;

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
    final double thickness = _thickness;

    final double played = _preview ??
        (_totalMs == 0 ? 0 : (widget.position.inMilliseconds / _totalMs).clamp(0.0, 1.0));
    final double buffered =
        _totalMs == 0 ? 0 : (widget.buffered.inMilliseconds / _totalMs).clamp(0.0, 1.0);

    // The unplayed remainder stays translucent over glass; the old opaque
    // grey filled a solid slab onto whatever it sat on.
    final Color remainingColor = Tokens.border;
    final Color bufferedColor =
        _interactive ? Tokens.textMuted : Tokens.border;
    final Color playedColor = _interactive ? Tokens.text : Tokens.border;

    return MouseRegion(
      cursor: _interactive ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: _hitHeight),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final double width = constraints.maxWidth;
            final double shownFraction =
                (_preview ?? played).clamp(0.0, 1.0);
            final bool showPreview =
                _interactive && (_hovered || _preview != null);

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
                    clipBehavior: Clip.none,
                    children: <Widget>[
                      _segment(1, remainingColor),
                      _segment(buffered, bufferedColor),
                      _segment(played, playedColor),
                      if (showPreview)
                        Positioned(
                          // Centre the thumb on the shown position; the track
                          // is thin, so it may overflow a hair — Clip.none
                          // lets it grow out of the hairline.
                          left: shownFraction * width - Tokens.seekThumbSize / 2,
                          top: thickness / 2 - Tokens.seekThumbSize / 2,
                          child: Container(
                            width: Tokens.seekThumbSize,
                            height: Tokens.seekThumbSize,
                            decoration: ShapeDecoration(
                              color: playedColor,
                              shape: const CircleBorder(),
                            ),
                          ),
                        ),
                      if (showPreview)
                        Positioned(
                          // Above the thumb, clamped to the edges so the tag
                          // never escapes the bar's own width.
                          left: (shownFraction * width)
                              .clamp(Tokens.s24, math.max(Tokens.s24, width - Tokens.s24)),
                          top: -Tokens.s12,
                          child: FractionalTranslation(
                            translation: const Offset(-0.5, -1),
                            child: _HoverTimePreview(
                              position: _at(shownFraction),
                            ),
                          ),
                        ),
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

/// The hover time preview: a small glass tag with the position the pointer is
/// over. Mouse-only affordance — on touch nothing shows, since a finger on the
/// bar already thickens it and the seek commits on release.
class _HoverTimePreview extends StatelessWidget {
  const _HoverTimePreview({required this.position});

  final Duration position;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      tier: GlassTier.thin,
      shape: Tokens.shapePill,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Tokens.s8,
          vertical: Tokens.s4,
        ),
        child: Text(
          formatDuration(position),
          style: Tokens.caption,
        ),
      ),
    );
  }
}
