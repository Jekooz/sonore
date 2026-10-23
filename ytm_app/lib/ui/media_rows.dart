import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../audio/playback_controller.dart';
import '../audio/track.dart';
import '../data/models.dart';
import '../features/now_playing/artwork.dart';
import '../routing/app_router.dart';
import '../theme/tokens.dart';
import 'art_tile.dart';
import 'context_menu.dart';
import 'media_actions.dart';
import 'track_row.dart';

/// What a tap on a row or card does, shared by every list in the app.
///
/// A playable item is played *in the context of its own list*, which is the
/// spec's rule ("that row becomes the queue, starting at that row"); a
/// collection opens its page. Nothing here invents a queue out of a single row.
void openMediaItem(
  BuildContext context,
  WidgetRef ref,
  MediaItem item,
  List<MediaItem> siblings,
) {
  final Track? track = item.track;
  if (track != null) {
    final List<Track> queue = siblings
        .map((MediaItem sibling) => sibling.track)
        .whereType<Track>()
        .toList(growable: false);
    ref
        .read(playbackProvider.notifier)
        .playFromContext(queue.isEmpty ? <Track>[track] : queue, track);
    return;
  }

  final CollectionRef? target = item.collection;
  if (target != null) {
    openCollection(context, target);
  }
}

/// Opens a collection page inside the destination the user is already in, so
/// the navigation stays put and Back returns to the list they came from.
void openCollection(BuildContext context, CollectionRef target) {
  context.go(collectionLocation(context, target));
}

/// One row of a list: artwork, title, metadata, plus its overflow menu and the
/// secondary (right-click / long-press) gesture that opens the same menu.
class MediaRow extends ConsumerWidget {
  const MediaRow({
    super.key,
    required this.item,
    required this.siblings,
    this.trailing,
    this.isPlaying = false,
  });

  final MediaItem item;
  final List<MediaItem> siblings;
  final Widget? trailing;
  final bool isPlaying;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<ContextMenuEntry> entries = mediaContextMenu(
      context: context,
      ref: ref,
      item: item,
      siblings: siblings
          .map((MediaItem sibling) => sibling.track)
          .whereType<Track>()
          .toList(growable: false),
    );

    return Builder(
      builder: (BuildContext rowContext) => GestureDetector(
        onSecondaryTapDown: (TapDownDetails details) => showContextMenu(
          rowContext,
          position: details.globalPosition,
          entries: entries,
        ),
        onLongPress: () => showContextMenuAt(rowContext, entries),
        child: TrackRow(
          title: item.title,
          subtitle: item.subtitle,
          // Resolved through the artwork seam like Now Playing, so tests and
          // goldens never fetch an image and the app has one cache path.
          artImage: ref.watch(artworkResolverProvider)(item.artworkUrl),
          isPlaying: isPlaying,
          onTap: () => openMediaItem(rowContext, ref, item, siblings),
          trailing:
              trailing ??
              ContextMenuButton(
                entries: entries,
                semanticLabel: 'Actions for ${item.title}',
              ),
        ),
      ),
    );
  }
}

/// The card's artwork, optionally wrapped in a [Hero] so it can fly into the
/// destination collection page. Hero only exists when the screen built this
/// card with a unique [heroTag].
class _CardArt extends StatelessWidget {
  const _CardArt({required this.heroTag, required this.child});

  final String? heroTag;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (heroTag == null) return child;
    return Hero(tag: heroTag!, child: child);
  }
}

/// An artwork card for the Home rails.
class MediaCard extends ConsumerWidget {
  const MediaCard({
    super.key,
    required this.item,
    required this.siblings,
    this.isCurrent = false,
    this.heroTag,
  });

  final MediaItem item;
  final List<MediaItem> siblings;
  final bool isCurrent;

  /// Non-null for the first card in a screen's build that shows a given
  /// artwork, so an artwork can fly into a collection page without ever
  /// creating duplicate hero tags (Home assigns them first-come).
  final String? heroTag;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<ContextMenuEntry> entries = mediaContextMenu(
      context: context,
      ref: ref,
      item: item,
      siblings: siblings
          .map((MediaItem sibling) => sibling.track)
          .whereType<Track>()
          .toList(growable: false),
    );

    return SizedBox(
      width: Tokens.artTileSize,
      child: Builder(
        builder: (BuildContext cardContext) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => openMediaItem(cardContext, ref, item, siblings),
          onSecondaryTapDown: (TapDownDetails details) => showContextMenu(
            cardContext,
            position: details.globalPosition,
            entries: entries,
          ),
          onLongPress: () => showContextMenuAt(cardContext, entries),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _CardArt(
                heroTag: heroTag,
                child: ArtTile(
                  size: Tokens.artTileSize,
                  radius: Tokens.rCard,
                  image: ref.watch(artworkResolverProvider)(item.artworkUrl),
                ),
              ),
              const SizedBox(height: Tokens.s8),
              // The text block takes whatever height is left and is allowed to
              // shrink, so a large text scale clips a line instead of
              // overflowing the rail.
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        item.title,
                        style: isCurrent
                            ? Tokens.rowTitleActive
                            : Tokens.rowTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(height: Tokens.s4),
                    Flexible(
                      child: Text(
                        item.subtitle.isEmpty
                            ? item.kind.badge ?? ''
                            : item.subtitle,
                        style: Tokens.caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
