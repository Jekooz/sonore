import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../audio/playback_controller.dart';
import '../../audio/playback_state.dart';
import '../../audio/track.dart';
import '../../routing/destinations.dart';
import '../../theme/icons.dart';
import '../../theme/tokens.dart';
import '../../ui/context_menu.dart';
import '../../ui/confirm_dialog.dart';
import '../../ui/format.dart';
import '../../ui/media_actions.dart';
import '../../ui/pill_button.dart';
import '../../ui/screen_header.dart';
import '../../ui/screen_states.dart';
import '../../ui/track_row.dart';
import '../now_playing/artwork.dart';

/// The dedicated Queue screen (design.md section F).
///
/// Now Playing's panel is the glanceable "Up Next"; this screen is where the
/// queue is actually edited. It is a real list with real consequences — every
/// control here changes what plays next through the same
/// [PlaybackController] the transport uses, so the Now Playing bar and Now Playing
/// move with it immediately (§F).
///
/// Two affordances exist for reordering because the spec asks for both: drag
/// handles for pointer and touch, and focusable move buttons, which are what
/// makes reordering reachable from the keyboard.
class QueueScreen extends ConsumerWidget {
  const QueueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlaybackState state = ref.watch(playbackProvider);
    final PlaybackController controller = ref.read(playbackProvider.notifier);

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: <Widget>[
            ScreenHeader(
              title: 'Queue',
              onBack: () => context.go(AppDestination.nowPlaying.path),
              backLabel: 'Back to Now Playing',
            ),
            if (!state.hasTrack)
              const Expanded(
                child: StateMessage(
                  message: 'Nothing is queued.',
                  footnote: 'Play a song and the queue shows up here.',
                ),
              )
            else
              Expanded(child: _QueueBody(state: state, controller: controller)),
          ],
        ),
      ),
    );
  }
}

class _QueueBody extends ConsumerWidget {
  const _QueueBody({required this.state, required this.controller});

  final PlaybackState state;
  final PlaybackController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ArtworkResolver artwork = ref.watch(artworkResolverProvider);
    final Track current = state.current!;
    final List<Track> upNext = state.upNext;
    final double margin = Tokens.pageMargin(MediaQuery.sizeOf(context).width);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // §F: "Autoplay has a visible on/off state." This is the same persisted
        // mode the transport's autoplay behaviour reads.
        SwitchListTile(
          value: state.autoplay,
          activeThumbColor: Tokens.text,
          title: const Text('Autoplay', style: Tokens.rowTitle),
          subtitle: const Text(
            'Keeps playing real recommendations when the queue runs out.',
            style: Tokens.caption,
          ),
          onChanged: controller.setAutoplay,
        ),
        if (state.shuffle)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: margin),
            child: const Text(
              'Shuffle is on. The service exposes no separate collection order, '
              'so the order below is the play order.',
              style: Tokens.caption,
            ),
          ),
        const _SectionLabel('Now playing'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Tokens.s8),
          child: TrackRow(
            title: current.title,
            subtitle: current.subtitle,
            artImage: artwork(current.artworkUrl),
            isPlaying: true,
            trailing: Text(
              formatDuration(current.duration),
              style: Tokens.caption,
            ),
          ),
        ),
        _SectionLabel(
          upNext.isEmpty
              ? 'Nothing is up next'
              : 'Next up · ${upNext.length}',
        ),
        Expanded(
          child: upNext.isEmpty
              ? const StateMessage(
                  message: 'Nothing is up next.',
                  footnote: 'Autoplay adds more when this track ends.',
                )
              : ReorderableListView.builder(
                  padding: const EdgeInsets.only(bottom: Tokens.s16),
                  // The handles below are deliberate: the spec asks for visible
                  // drag handles, not for the whole row to be a drag target.
                  buildDefaultDragHandles: false,
                  itemCount: upNext.length,
                  // onReorderItem already accounts for the dragged row being
                  // removed, so the target index needs no correction (this is
                  // what replaced the deprecated onReorder).
                  onReorderItem: (int from, int to) => controller.move(
                    state.index + 1 + from,
                    state.index + 1 + to,
                  ),
                  itemBuilder: (BuildContext context, int index) {
                    final Track track = upNext[index];
                    return _QueueRow(
                      // A queue may hold the same track twice, so the id alone
                      // is not a unique key.
                      key: ValueKey<String>('${track.id}@$index'),
                      track: track,
                      position: index,
                      lastPosition: upNext.length - 1,
                      queueIndex: state.index + 1 + index,
                      siblings: state.queue,
                      artwork: artwork,
                      controller: controller,
                    );
                  },
                ),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: margin),
          child: Center(
            child: PillButton(
              icon: AppIcons.close,
              label: 'Clear queue',
              onPressed: () => _confirmClear(context),
            ),
          ),
        ),
        const SizedBox(height: Tokens.s16),
      ],
    );
  }

  /// Clearing the queue is consequential (it stops playback and drops the
  /// list), so it asks first — the spec's rule for destructive actions.
  Future<void> _confirmClear(BuildContext context) async {
    final bool? confirmed = await confirmDialog(
      context,
      title: 'Clear the queue?',
      body: 'Playback stops and the queue is emptied. Your music, likes and '
          'sign-in are not affected.',
      confirmLabel: 'Clear',
    );
    if (confirmed ?? false) controller.clear();
  }
}

class _QueueRow extends ConsumerWidget {
  const _QueueRow({
    super.key,
    required this.track,
    required this.position,
    required this.lastPosition,
    required this.queueIndex,
    required this.siblings,
    required this.artwork,
    required this.controller,
  });

  final Track track;

  /// Position within the upcoming part of the queue.
  final int position;

  /// The last upcoming position, so the end-of-list control is not offered.
  final int lastPosition;

  /// Position within the whole queue.
  final int queueIndex;

  final List<Track> siblings;
  final ArtworkResolver artwork;
  final PlaybackController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TrackRow(
      title: track.title,
      subtitle: track.subtitle,
      artImage: artwork(track.artworkUrl),
      onTap: () => controller.playAt(queueIndex),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // Keyboard-reachable reordering: IconButton is focusable and answers
          // to Enter and Space, which a drag handle cannot do. The ends of the
          // list simply do not offer the impossible direction.
          if (position > 0)
            IconButton(
              icon: const Icon(AppIcons.caretUp, size: Tokens.iconSize),
              color: Tokens.textSecondary,
              tooltip: 'Move ${track.title} up',
              onPressed: () => controller.move(queueIndex, queueIndex - 1),
            ),
          if (position < lastPosition)
            IconButton(
              icon: const Icon(AppIcons.caretDown, size: Tokens.iconSize),
              color: Tokens.textSecondary,
              tooltip: 'Move ${track.title} down',
              onPressed: () => controller.move(queueIndex, queueIndex + 1),
            ),
          ContextMenuButton(
            entries: trackContextMenu(
              context: context,
              ref: ref,
              track: track,
              siblings: siblings,
              extraEntries: <ContextMenuEntry>[
                ContextMenuEntry(
                  icon: AppIcons.caretUp,
                  label: 'Move up',
                  onSelected: () => controller.move(queueIndex, queueIndex - 1),
                ),
                ContextMenuEntry(
                  icon: AppIcons.caretDown,
                  label: 'Move down',
                  onSelected: () => controller.move(queueIndex, queueIndex + 1),
                ),
                ContextMenuEntry(
                  icon: AppIcons.close,
                  label: 'Remove from queue',
                  onSelected: () => controller.removeAt(queueIndex),
                ),
              ],
            ),
            semanticLabel: 'Actions for ${track.title}',
          ),
          ReorderableDragStartListener(
            index: position,
            child: Semantics(
              label: 'Reorder ${track.title}',
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: Tokens.s4),
                child: Icon(
                  AppIcons.dotsThreeVertical,
                  size: Tokens.iconSize,
                  color: Tokens.textMuted,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        left: Tokens.pageMarginPhone,
        top: Tokens.s16,
        bottom: Tokens.s8,
      ),
      child: Text(text, style: Tokens.sectionHeader),
    );
  }
}
