import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'art_tile.dart';

/// One track row: 48px artwork (rSmall), title and subtitle, optional trailing.
///
/// Pressed rows fill with [Tokens.surfaceRaised] (not a ripple — the spec bans
/// Material ripples). The playing row marks itself with the accent, the only
/// active-state color.
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

  /// Marks the playing track with the accent title.
  final bool isPlaying;

  @override
  State<TrackRow> createState() => _TrackRowState();
}

class _TrackRowState extends State<TrackRow> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (widget.onTap == null || _pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final TextStyle titleStyle =
        widget.isPlaying ? Tokens.rowTitleActive : Tokens.rowTitle;

    return Semantics(
      button: widget.onTap != null,
      selected: widget.isPlaying,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _setPressed(true),
        onTapUp: (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        onTap: widget.onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _pressed ? Tokens.surfaceRaised : Tokens.transparent,
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
                        Text(
                          widget.title,
                          style: titleStyle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
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
    );
  }
}
