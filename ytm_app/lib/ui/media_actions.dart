import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/playback_controller.dart';
import '../audio/track.dart';
import '../data/api_client.dart';
import '../data/models.dart';
import '../data/ytm_repository.dart';
import '../theme/icons.dart';
import '../theme/tokens.dart';
import 'context_menu.dart';
import 'media_rows.dart';

/// The standard action set for a song, album, artist or playlist (spec section
/// 3.D), shared by every row in the app so the menus cannot drift apart.
///
/// Every entry here performs a real action:
///
/// * Play now / Play next / Add to queue drive the one [PlaybackController];
/// * Like writes through the sidecar's `/ratings` (ytmusicapi `rate_song`) and
///   then reflects the persisted state;
/// * Go to album / Go to artist appear only when the service supplied a real
///   id;
/// * Copy link copies the real YouTube Music URL for the item.
///
/// Playlist renaming, editing, removal and deletion are absent because the
/// sidecar has no endpoint for them, and the spec forbids placeholder items.
List<ContextMenuEntry> mediaContextMenu({
  required BuildContext context,
  required WidgetRef ref,
  required MediaItem item,
  required List<Track> siblings,
}) {
  final Track? track = item.track;
  if (track != null) {
    return trackContextMenu(
      context: context,
      ref: ref,
      track: track,
      siblings: siblings,
    );
  }

  final List<ContextMenuEntry> entries = <ContextMenuEntry>[];
  if (item.collection != null) {
    final CollectionRef target = item.collection!;
    entries.add(ContextMenuEntry(
      icon: AppIcons.playFill,
      label: 'Play now',
      onSelected: () => _playCollection(context, ref, target, PlayMode.now),
    ));
    entries.add(ContextMenuEntry(
      icon: AppIcons.queue,
      label: 'Play next',
      onSelected: () => _playCollection(context, ref, target, PlayMode.next),
    ));
    entries.add(ContextMenuEntry(
      icon: AppIcons.plus,
      label: 'Add to queue',
      onSelected: () => _playCollection(context, ref, target, PlayMode.append),
    ));
  }

  final String? shareUrl = shareUrlOf(item);
  if (shareUrl != null) {
    entries.add(ContextMenuEntry(
      icon: AppIcons.linkSimple,
      label: 'Copy link',
      onSelected: () async {
        await Clipboard.setData(ClipboardData(text: shareUrl));
        if (context.mounted) showAppMessage(context, 'Link copied');
      },
    ));
  }

  return entries;
}

/// The same standard action set for a bare [Track].
///
/// The Queue screen works in tracks, not service rows, and section F requires it
/// to reuse the standard actions rather than inventing its own. [extraEntries]
/// is where a surface adds what only it can do (the queue adds Move up, Move
/// down and Remove) without forking the shared list.
List<ContextMenuEntry> trackContextMenu({
  required BuildContext context,
  required WidgetRef ref,
  required Track track,
  required List<Track> siblings,
  List<ContextMenuEntry> extraEntries = const <ContextMenuEntry>[],
}) {
  final PlaybackController controller = ref.read(playbackProvider.notifier);
  final List<ContextMenuEntry> entries = <ContextMenuEntry>[
    ContextMenuEntry(
      icon: AppIcons.playFill,
      label: 'Play now',
      // With the queue itself as the context this reads "play this row", which
      // is the spec's row rule and exactly what queue order changes must do.
      onSelected: () => controller.playFromContext(siblings, track),
    ),
    ContextMenuEntry(
      icon: AppIcons.queue,
      label: 'Play next',
      onSelected: () => controller.playNext(<Track>[track]),
    ),
    ContextMenuEntry(
      icon: AppIcons.plus,
      label: 'Add to queue',
      onSelected: () => controller.addToQueue(<Track>[track]),
    ),
    ContextMenuEntry(
      icon: track.isLiked ? AppIcons.heartFill : AppIcons.heart,
      label: track.isLiked ? 'Remove like' : 'Like',
      onSelected: () => _setLike(ref, context, track, liked: !track.isLiked),
    ),
    if (track.albumId != null)
      ContextMenuEntry(
        icon: AppIcons.disc,
        label: 'Go to album',
        onSelected: () => _open(
          context,
          CollectionRef(CollectionKind.album, track.albumId!),
        ),
      ),
    if (track.artistId != null)
      ContextMenuEntry(
        icon: AppIcons.user,
        label: 'Go to artist',
        onSelected: () => _open(
          context,
          CollectionRef(CollectionKind.artist, track.artistId!),
        ),
      ),
    ...extraEntries,
  ];

  if (track.id.isNotEmpty) {
    entries.add(ContextMenuEntry(
      icon: AppIcons.linkSimple,
      label: 'Copy link',
      onSelected: () async {
        await Clipboard.setData(ClipboardData(text: trackShareUrl(track)));
        if (context.mounted) showAppMessage(context, 'Link copied');
      },
    ));
  }

  return entries;
}

/// The real, working YouTube Music URL for a track.
String trackShareUrl(Track track) =>
    'https://music.youtube.com/watch?v=${track.id}';

enum PlayMode { now, next, append }

void _open(BuildContext context, CollectionRef target) =>
    openCollection(context, target);

/// Resolves a collection's tracks through the same provider the page uses, so
/// acting on a card costs one fetch and shares its cache.
Future<void> _playCollection(
  BuildContext context,
  WidgetRef ref,
  CollectionRef target,
  PlayMode mode,
) async {
  final PlaybackController controller = ref.read(playbackProvider.notifier);
  try {
    final Collection collection =
        await ref.read(collectionProvider(target).future);
    final List<Track> tracks = collection.playableTracks;
    if (tracks.isEmpty) {
      if (context.mounted) {
        showAppMessage(context, '“${collection.title}” has nothing to play.');
      }
      return;
    }
    switch (mode) {
      case PlayMode.now:
        controller.setQueue(tracks);
      case PlayMode.next:
        controller.playNext(tracks);
      case PlayMode.append:
        controller.addToQueue(tracks);
    }
  } on YtmException catch (error) {
    // A real failure, reported as a message rather than a silent no-op. The
    // collection page itself still shows its own retry.
    if (context.mounted) showAppMessage(context, error.message);
  }
}

/// Likes or unlikes through the service, then reflects the persisted state.
///
/// The optimistic toggle happens only after the service accepts the change, so
/// the heart never shows a state the account does not actually have.
Future<void> _setLike(
  WidgetRef ref,
  BuildContext context,
  Track track, {
  required bool liked,
}) async {
  final YtmRepository repository = ref.read(ytmRepositoryProvider);
  try {
    await repository.setLike(track, liked: liked);
  } on YtmException catch (error) {
    if (context.mounted) showAppMessage(context, error.message);
    return;
  }

  final PlaybackController controller = ref.read(playbackProvider.notifier);
  if (controller.currentTrackId == track.id && track.isLiked != liked) {
    controller.toggleLike();
  }
  // Lists come from the service, so the persisted rating is re-read rather than
  // patched locally.
  ref.invalidate(homeProvider);
  ref.invalidate(libraryProvider);
  if (context.mounted) {
    showAppMessage(context, liked ? 'Added to liked songs' : 'Removed from liked songs');
  }
}

/// The real, working YouTube Music URL for an item, or null when there is none.
String? shareUrlOf(MediaItem item) {
  final Track? track = item.track;
  if (track != null && track.id.isNotEmpty) {
    return 'https://music.youtube.com/watch?v=${track.id}';
  }
  final CollectionRef? ref = item.collection;
  if (ref == null) return null;
  return switch (ref.kind) {
    CollectionKind.album => 'https://music.youtube.com/browse/${ref.id}',
    CollectionKind.playlist =>
      'https://music.youtube.com/playlist?list=${ref.id}',
    CollectionKind.artist => 'https://music.youtube.com/channel/${ref.id}',
  };
}

/// A short, on-token message. ScaffoldMessenger's default SnackBar would use
/// Material's own surface colours, which the spec bans, so the styling is
/// explicit here.
void showAppMessage(BuildContext context, String message) {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  messenger.clearSnackBars();
  messenger.showSnackBar(
    SnackBar(
      content: Text(message, style: Tokens.subtitle.copyWith(color: Tokens.text)),
      backgroundColor: Tokens.surfaceRaised,
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      duration: const Duration(seconds: 3),
      shape: Tokens.shapeFor(Tokens.rCard),
      margin: const EdgeInsets.all(Tokens.s16),
    ),
  );
}
