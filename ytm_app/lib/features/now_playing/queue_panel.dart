import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../audio/playback_controller.dart';
import '../../audio/playback_state.dart';
import '../../audio/track.dart';
import '../../theme/icons.dart';
import '../../theme/tokens.dart';
import '../../ui/format.dart';
import '../../ui/screen_states.dart';
import '../../ui/track_row.dart';
import 'artwork.dart';

/// The queue, as a panel.
///
/// Glanceable: what is playing now (with the live bars) and what comes next,
/// one tap to jump anywhere. Full editing lives on the Queue screen reachable
/// from the footer — the panel manages travel, not edits.
class QueuePanel extends ConsumerWidget {
  const QueuePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlaybackState state = ref.watch(playbackProvider);
    final Track? current = state.current;
    final ArtworkResolver artwork = ref.watch(artworkResolverProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: state.hasTrack
              ? ListView(
                  padding: EdgeInsets.zero,
                  children: <Widget>[
                    const Padding(
                      padding: EdgeInsets.fromLTRB(
                        Tokens.s16,
                        Tokens.s16,
                        Tokens.s16,
                        Tokens.s8,
                      ),
                      child: Text('Now playing', style: Tokens.sectionHeader),
                    ),
                    if (current != null)
                      TrackRow(
                        title: current.title,
                        subtitle: current.subtitle,
                        isPlaying: true,
                        artImage: artwork(current.artworkUrl),
                        trailing: Text(
                          formatDuration(current.duration),
                          style: Tokens.caption,
                        ),
                      ),
                    const Divider(
                      color: Tokens.border,
                      height: Tokens.s32,
                      indent: Tokens.s8,
                      endIndent: Tokens.s8,
                    ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(
                        Tokens.s16,
                        0,
                        Tokens.s16,
                        Tokens.s8,
                      ),
                      child: Text('Up next', style: Tokens.sectionHeader),
                    ),
                    if (state.upNext.isEmpty)
                      const _PanelEmpty()
                    else
                      for (
                        int index = 0;
                        index < state.upNext.length;
                        index++
                      )
                        _UpNextRow(
                          index: index,
                          track: state.upNext[index],
                          artwork: artwork,
                        ),
                    const SizedBox(height: Tokens.s16),
                  ],
                )
              : const StateMessage(message: 'Nothing is queued.'),
        ),
        // Full editing stays reachable, out of the way: a footer link rather
        // than controls that would clutter the glanceable list.
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Tokens.s16,
            0,
            Tokens.s16,
            Tokens.s12,
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Semantics(
              button: true,
              label: 'Open the full queue',
              child: TextButton.icon(
                icon: const Icon(
                  AppIcons.listBullets,
                  size: Tokens.iconSize - 4,
                  color: Tokens.textSecondary,
                ),
                label: const Text(
                  'Open full queue',
                  style: Tokens.subtitle,
                ),
                onPressed: () => context.go('/now-playing/queue'),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _UpNextRow extends ConsumerWidget {
  const _UpNextRow({
    required this.index,
    required this.track,
    required this.artwork,
  });

  final int index;
  final Track track;
  final ArtworkResolver artwork;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlaybackState state = ref.watch(playbackProvider);

    return TrackRow(
      title: track.title,
      subtitle: track.artist,
      artImage: artwork(track.artworkUrl),
      trailing: Text(
        formatDuration(track.duration),
        style: Tokens.caption,
      ),
      onTap: () =>
          ref.read(playbackProvider.notifier).playAt(state.index + 1 + index),
    );
  }
}

class _PanelEmpty extends StatelessWidget {
  const _PanelEmpty();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: Tokens.s16, vertical: Tokens.s24),
      child: Text('Nothing is up next.', style: Tokens.subtitle),
    );
  }
}
