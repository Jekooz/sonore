import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../audio/playback_controller.dart';
import '../../audio/playback_state.dart';
import '../../audio/track.dart';
import '../../data/models.dart';
import '../../data/ytm_repository.dart';
import '../../theme/icons.dart';
import '../../theme/tokens.dart';
import '../../ui/art_tile.dart';
import '../now_playing/artwork.dart';
import '../../ui/context_menu.dart';
import '../../ui/data_states.dart';
import '../../ui/media_actions.dart';
import '../../ui/media_rows.dart';
import '../../ui/pill_button.dart';
import '../../ui/pressable.dart';
import '../../ui/screen_states.dart';

/// One album, playlist or artist page.
///
/// The sidecar returns a single `{kind, title, subtitle, thumbnails, tracks}`
/// payload for all three kinds, so this is one screen. Play queues the whole
/// collection through the same [PlaybackController] every other screen uses.
class CollectionScreen extends ConsumerWidget {
  const CollectionScreen({super.key, required this.target});

  final CollectionRef target;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // Back returns to the list this page was opened from.
        const Padding(
          padding: EdgeInsets.only(
            left: Tokens.s8,
            top: Tokens.s8,
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: _BackButton(),
          ),
        ),
        Expanded(
          child: ConnectionGate(
            loading: const _CollectionLoading(),
            child: DataStateView<Collection>(
              value: ref.watch(collectionProvider(target)),
              onRetry: () => ref.invalidate(collectionProvider),
              loading: const _CollectionLoading(),
              data: (Collection collection) =>
                  _CollectionView(collection: collection),
            ),
          ),
        ),
      ],
    );
  }
}

class _BackButton extends StatelessWidget {
  const _BackButton();

  @override
  Widget build(BuildContext context) {
    return Pressable(
      semanticLabel: 'Back',
      // The page is nested inside its destination's branch, so popping returns
      // to the list it was opened from.
      onTap: () => context.pop(),
      child: const Icon(
        AppIcons.caretLeft,
        size: Tokens.iconSize,
        color: Tokens.text,
      ),
    );
  }
}

class _CollectionView extends ConsumerWidget {
  const _CollectionView({required this.collection});

  final Collection collection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool isDesktop =
        MediaQuery.sizeOf(context).width >= Tokens.breakpointDesktop;
    final double margin =
        isDesktop ? Tokens.pageMarginDesktop : Tokens.pageMarginPhone;
    // Computed once: items the service returned without a playable target are
    // not rows at all, so they never become a dead row.
    final List<MediaItem> rows = collection.tracks
        .where((MediaItem item) => item.isPlayable)
        .toList(growable: false);
    final String? currentTrackId = ref.watch(
      playbackProvider.select((PlaybackState state) => state.current?.id),
    );

    return ListView.builder(
      padding: EdgeInsets.fromLTRB(
        margin,
        Tokens.s16,
        margin,
        Tokens.s24,
      ),
      itemCount: rows.length + 1,
      itemBuilder: (BuildContext context, int index) {
        if (index == 0) {
          return _CollectionHeader(collection: collection);
        }
        final MediaItem item = rows[index - 1];
        return MediaRow(
          item: item,
          siblings: collection.tracks,
          isPlaying: item.track!.id == currentTrackId,
        );
      },
    );
  }
}

class _CollectionHeader extends ConsumerWidget {
  const _CollectionHeader({required this.collection});

  final Collection collection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<Track> playable = collection.playableTracks;
    final bool canPlay = playable.isNotEmpty;
    final PlaybackController controller = ref.read(playbackProvider.notifier);
    final bool isArtist = collection.ref.kind == CollectionKind.artist;

    return Padding(
      padding: const EdgeInsets.only(bottom: Tokens.s16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ArtTile(
            size: Tokens.collectionArtSize,
            // Artists are pictured in a circle, albums and playlists in a card.
            radius: isArtist ? Tokens.rLarge : Tokens.rCard,
            // Through the artwork seam, as everywhere else.
            image: ref.watch(artworkResolverProvider)(collection.artworkUrl),
          ),
          const SizedBox(width: Tokens.s16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(collection.ref.kind.name.toUpperCase(),
                    style: Tokens.caption),
                const SizedBox(height: Tokens.s4),
                Text(
                  collection.title,
                  style: Tokens.nowPlayingTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (collection.subtitle.isNotEmpty) ...<Widget>[
                  const SizedBox(height: Tokens.s4),
                  Text(
                    collection.subtitle,
                    style: Tokens.subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: Tokens.s16),
                Wrap(
                  spacing: Tokens.s8,
                  runSpacing: Tokens.s8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    PillButton(
                      icon: AppIcons.playFill,
                      label: 'Play',
                      isActive: true,
                      // An empty collection offers no Play rather than a button
                      // that does nothing.
                      onPressed:
                          canPlay ? () => controller.setQueue(playable) : null,
                    ),
                    PillButton(
                      icon: AppIcons.plus,
                      label: 'Add to queue',
                      onPressed:
                          canPlay ? () => controller.addToQueue(playable) : null,
                    ),
                    ContextMenuButton(
                      entries: mediaContextMenu(
                        context: context,
                        ref: ref,
                        item: MediaItem(
                          kind: switch (collection.ref.kind) {
                            CollectionKind.album => MediaKind.album,
                            CollectionKind.playlist => MediaKind.playlist,
                            CollectionKind.artist => MediaKind.artist,
                          },
                          title: collection.title,
                          collection: collection.ref,
                        ),
                        siblings: const <Track>[],
                      ),
                      semanticLabel: 'Actions for ${collection.title}',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The page's loading state: a header-shaped skeleton above list rows, so the
/// layout does not jump when the real content arrives.
class _CollectionLoading extends StatelessWidget {
  const _CollectionLoading();

  @override
  Widget build(BuildContext context) {
    final double margin = MediaQuery.sizeOf(context).width >=
            Tokens.breakpointDesktop
        ? Tokens.pageMarginDesktop
        : Tokens.pageMarginPhone;

    return Padding(
      padding: EdgeInsets.all(margin),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Skeleton(
                width: Tokens.collectionArtSize,
                height: Tokens.collectionArtSize,
                radius: Tokens.rCard,
              ),
              SizedBox(width: Tokens.s16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Skeleton(width: Tokens.s48 * 4),
                    SizedBox(height: Tokens.s8),
                    Skeleton(width: Tokens.s48 * 6),
                    SizedBox(height: Tokens.s16),
                    Skeleton(width: Tokens.s48 * 3),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: Tokens.s24),
          // Fills the height left by the header. A scrollable laid directly in
          // this Column would be handed unbounded height and cannot lay out.
          Expanded(child: ListSkeleton(rows: 4, padding: EdgeInsets.zero)),
        ],
      ),
    );
  }
}
