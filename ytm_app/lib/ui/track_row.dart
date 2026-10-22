import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'art_tile.dart';
import 'live_badge.dart';

/// One track row: 48px artwork (rSmall), title and subtitle, optional trailing.
///
/// Rows are real controls with spoken states: hover and pressed fill
/// ([Tokens.glassThin] and [Tokens.glassThick]), keyboard focus rings via
/// [FocusableActionDetector], and a [LiveBadge] beside the title of the playing
/// track (no accent color — the mark plus weight carry it).
class TrackRow extends StatefulWidget {
  const TrackRow({
    super.key,
    required this.title,
    required this.subtitle,
    this.artUrl,
    this.artImage,
    this.trailing,
    this.onTap,
    this.isPlaying = false,
  });

  final String title;
  final String subtitle;
  final String? artUrl;
  final ImageProvider? artImage;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Marks the playing track with the badge and the heavier title.
  final bool isPlaying;

  @override
  State<TrackRow> createState() => _TrackRowState();
}

class _TrackRowState extends State<TrackRow> {
  bool _pressed = false;
  bool _hovered = false;
  bool _focused = false;

  void _setPressed(bool value) {
    if (widget.onTap == null || _pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final TextStyle titleStyle =
        widget.isPlaying ? Tokens.rowTitleActive : Tokens.rowTitle;

    final Color fill = _pressed
        ? Tokens.glassThick
        : _hovered || _focused
            ? Tokens.glassThin
            : Tokens.transparent;

    return Semantics(
      button: widget.onTap != null,
      selected: widget.isPlaying,
      child: FocusableActionDetector(
        onShowFocusHighlight: (bool value) =>
            setState(() => _focused = value),
        onShowHoverHighlight: (bool value) => setState(() => _hovered = value),
        mouseCursor: widget.onTap == null
            ? MouseCursor.defer
            : SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => _setPressed(true),
          onTapUp: (_) => _setPressed(false),
          onTapCancel: () => _setPressed(false),
          onTap: widget.onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: fill,
              borderRadius: _hovered || _pressed || _focused
                  ? Tokens.rSmallBorder
                  : null,
            ),
            child: SizedBox(
              height: Tokens.listRowHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Tokens.s8),
                child: Row(
                  children: <Widget>[
                    ArtTile(
                      size: Tokens.artThumbSize,
                      radius: Tokens.rSmall,
                      url: widget.artUrl,
                      image: widget.artImage,
                    ),
                    const SizedBox(width: Tokens.s12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Flexible(
                                child: Text(
                                  widget.title,
                                  style: titleStyle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (widget.isPlaying) ...<Widget>[
                                const SizedBox(width: Tokens.s8),
                                ExcludeSemantics(
                                  child: LiveBadge(
                                    isPlaying: widget.isPlaying,
                                  ),
                                ),
                              ],
                            ],
                          ),
                          Text(
                            widget.subtitle,
                            style: Tokens.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    if (widget.trailing != null) ...<Widget>[
                      const SizedBox(width: Tokens.s12),
                      widget.trailing!,
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
