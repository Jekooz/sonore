import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../audio/playback_controller.dart';
import '../../audio/playback_state.dart';
import '../../audio/track.dart';
import '../../theme/tokens.dart';
import '../../ui/format.dart';
import '../../ui/screen_states.dart';
import '../../ui/track_row.dart';
import 'artwork.dart';

/// The Now Playing queue panel for desktop layouts (spec: "desktop: queue
/// panel on the right").
///
/// It is a content panel, not floating chrome, so it uses the flat
/// [Tokens.surface] fill rather than glass. Tapping an upcoming track plays it.
/// Drag reordering, autoplay and clear belong to the Queue screen in a later
/// phase and are not stubbed here.
class QueuePanel extends ConsumerWidget {
  const QueuePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlaybackState state = ref.watch(playbackProvider);
    final Track? current = state.current;
    final ArtworkResolver artwork = ref.watch(artworkResolverProvider);

    return SizedBox(
      width: Tokens.queuePanelWidth,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: Tokens.surface,
          shape: Tokens.shapeFor(Tokens.rLarge),
        ),
        child: Padding(
          padding: const EdgeInsets.all(Tokens.s16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text('Up Next', style: Tokens.sectionHeader),
              const SizedBox(height: Tokens.s12),
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
              const Divider(color: Tokens.border, height: Tokens.s16),
              Expanded(
                child: state.upNext.isEmpty
                    ? const StateMessage(message: 'Nothing is up next.')
                    : ListView.builder(
                        padding: EdgeInsets.zero,
                        itemCount: state.upNext.length,
                        itemBuilder: (BuildContext context, int index) {
                          final Track track = state.upNext[index];
                          return TrackRow(
                            title: track.title,
                            subtitle: track.artist,
                            artImage: artwork(track.artworkUrl),
                            trailing: Text(
                              formatDuration(track.duration),
                              style: Tokens.caption,
                            ),
                            onTap: () => ref
                                .read(playbackProvider.notifier)
                                .playAt(state.index + 1 + index),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
