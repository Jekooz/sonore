import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../audio/track.dart';
import '../../data/models.dart';
import '../../theme/tokens.dart';
import '../../ui/art_tile.dart';
import '../../ui/format.dart';
import '../../ui/media_rows.dart';
import '../now_playing/artwork.dart';

/// The Home "Popular" rail: a numbered vertical track list beside the shelves.
///
/// Desktop widths only — the caller leaves it out below the breakpoint, where
/// the page becomes a single scrolling column. Tapping a row plays it in the
/// context of the rail, through the same [openMediaItem] path every other list
/// in the app uses.
class PopularRail extends StatelessWidget {
  const PopularRail({super.key, required this.tracks});

  final List<MediaItem> tracks;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: Tokens.popularRailWidth,
      child: Padding(
        padding: const EdgeInsets.only(
          top: Tokens.s24,
          right: Tokens.pageMarginDesktop,
          bottom: Tokens.shellBottomInset,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('Popular', style: Tokens.sectionHeader),
            const SizedBox(height: Tokens.s12),
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: tracks.length,
                itemBuilder: (BuildContext context, int index) => _PopularRow(
                  position: index + 1,
                  item: tracks[index],
                  siblings: tracks,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One numbered row: rank, art, title, artist, duration.
class _PopularRow extends ConsumerWidget {
  const _PopularRow({
    required this.position,
    required this.item,
    required this.siblings,
  });

  final int position;
  final MediaItem item;
  final List<MediaItem> siblings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? track = item.track;

    return Semantics(
      button: true,
      label: item.title,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => openMediaItem(context, ref, item, siblings),
          child: SizedBox(
            height: Tokens.listRowHeight,
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: Tokens.s24,
                  child: Text(
                    '$position',
                    style: Tokens.caption,
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(width: Tokens.s8),
                ArtTile(
                  size: Tokens.artThumbSize,
                  radius: Tokens.rSmall,
                  image: ref.watch(artworkResolverProvider)(item.artworkUrl),
                ),
                const SizedBox(width: Tokens.s12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        item.title,
                        style: Tokens.rowTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        item.subtitle,
                        style: Tokens.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (track?.duration != null)
                  Text(formatDuration(track!.duration), style: Tokens.caption),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
