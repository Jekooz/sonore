import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../audio/playback_controller.dart';
import '../../audio/playback_state.dart';
import '../../audio/track.dart';
import '../../routing/destinations.dart';
import '../../theme/icons.dart';
import '../../theme/tokens.dart';
import '../../ui/art_tile.dart';
import '../../ui/glass_surface.dart';
import '../../ui/pressable.dart';
import '../now_playing/artwork.dart';

/// The mini player that lives in the shell, not in a page.
///
/// Approved layout: a floating glass pill pinned to the bottom centre on every
/// screen except Now Playing — 64px tall, 48px art, title + artist, previous /
/// play-pause / next, and a thin accent line for position ÷ duration. Tap or
/// swipe up opens Now Playing.
///
/// It is hidden entirely while the queue is empty (there is nothing to show a
/// transport for) and on Now Playing itself, where the page is the player. It
/// is floating chrome, so it is built from [GlassSurface] and therefore honours
/// Reduce Transparency, and its width is capped so it stays a pill rather than
/// stretching across a wide window.
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlaybackState state = ref.watch(playbackProvider);
    final Track? track = state.current;

    if (track == null) return const SizedBox.shrink();

    final ArtworkResolver artwork = ref.watch(artworkResolverProvider);

    final double fraction = state.duration > Duration.zero
        ? (state.position.inMilliseconds / state.duration.inMilliseconds)
            .clamp(0.0, 1.0)
        : 0.0;

    void openNowPlaying() => context.go(AppDestination.nowPlaying.path);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: Tokens.miniPlayerMaxWidth),
      child: GlassSurface(
        isStrong: true,
        shape: Tokens.shapePill,
        child: SizedBox(
          height: Tokens.miniPlayerHeight,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              return Stack(
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Tokens.s12),
                    child: Row(
                      children: <Widget>[
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: openNowPlaying,
                          onVerticalDragEnd: (DragEndDetails details) {
                            if ((details.primaryVelocity ?? 0) < 0) {
                              openNowPlaying();
                            }
                          },
                          child: ArtTile(
                            size: Tokens.artThumbSize,
                            radius: Tokens.rSmall,
                            image: artwork(track.artworkUrl),
                          ),
                        ),
                        const SizedBox(width: Tokens.s12),
                        Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: openNowPlaying,
                            onVerticalDragEnd: (DragEndDetails details) {
                              if ((details.primaryVelocity ?? 0) < 0) {
                                openNowPlaying();
                              }
                            },
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  track.title,
                                  style: Tokens.rowTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  track.artist,
                                  style: Tokens.subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ),
                        Pressable(
                          onTap: ref.read(playbackProvider.notifier).previous,
                          semanticLabel: 'Previous',
                          child: const Icon(
                            AppIcons.skipBack,
                            size: Tokens.iconSize,
                            color: Tokens.text,
                          ),
                        ),
                        Pressable(
                          onTap:
                              ref.read(playbackProvider.notifier).togglePlayPause,
                          semanticLabel: state.isPlaying ? 'Pause' : 'Play',
                          child: Icon(
                            state.isPlaying
                                ? AppIcons.pauseFill
                                : AppIcons.playFill,
                            size: Tokens.iconSize,
                            color: Tokens.text,
                          ),
                        ),
                        Pressable(
                          onTap: ref.read(playbackProvider.notifier).next,
                          semanticLabel: 'Next',
                          child: const Icon(
                            AppIcons.skipForward,
                            size: Tokens.iconSize,
                            color: Tokens.text,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    left: 0,
                    bottom: 0,
                    child: SizedBox(
                      width: constraints.maxWidth * fraction,
                      height: Tokens.progressLineThin,
                      child: const ColoredBox(color: Tokens.accent),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
