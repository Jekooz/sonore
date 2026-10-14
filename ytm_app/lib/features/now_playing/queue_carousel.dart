import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../audio/playback_controller.dart';
import '../../audio/playback_state.dart';
import '../../audio/track.dart';
import '../../theme/tokens.dart';
import '../../ui/art_tile.dart';
import 'artwork.dart';

/// Fan carousel of the queue.
///
/// Spec: neighbours sit at scale 0.8, rotateY 35 degrees at perspective 0.001,
/// and fade to 0.35 opacity; the carousel snaps on a spring, and the current
/// artwork scales between 1.0 (playing) and 0.86 (paused). The transform is
/// driven by the page offset, so the motion follows the finger and is
/// interruptible.
///
/// Swiping changes track through the shared playback controller, so the mini
/// player and queue panel follow immediately.
class QueueCarousel extends ConsumerStatefulWidget {
  const QueueCarousel({super.key});

  @override
  ConsumerState<QueueCarousel> createState() => _QueueCarouselState();
}

class _QueueCarouselState extends ConsumerState<QueueCarousel> {
  late final PageController _pageController = PageController(
    viewportFraction: Tokens.carouselViewportFraction,
    initialPage: ref.read(playbackProvider).index,
  );

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final PlaybackState state = ref.watch(playbackProvider);
    if (!state.hasTrack) return const SizedBox.shrink();

    // Follow queue changes that did not come from this carousel (next/previous).
    ref.listen<int>(playbackProvider.select((PlaybackState s) => s.index),
        (int? previous, int next) {
      if (!_pageController.hasClients) return;
      final int shown = _pageController.page?.round() ?? next;
      if (shown == next) return;
      _pageController.animateToPage(
        next,
        duration: Tokens.dPageChange,
        curve: Tokens.curvePageChange,
      );
    });

    final ArtworkResolver artwork = ref.watch(artworkResolverProvider);

    return PageView.builder(
      controller: _pageController,
      itemCount: state.queue.length,
      onPageChanged: (int index) =>
          ref.read(playbackProvider.notifier).playAt(index),
      itemBuilder: (BuildContext context, int index) {
        final Track track = state.queue[index];

        return LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final double artSize =
                constraints.maxWidth.clamp(0.0, Tokens.artworkMaxPhone);

            return AnimatedBuilder(
              animation: _pageController,
              builder: (BuildContext context, Widget? child) {
                double delta = 0;
                if (_pageController.hasClients &&
                    _pageController.position.hasContentDimensions) {
                  delta = (_pageController.page ?? state.index.toDouble()) - index;
                }
                final double clamped = delta.clamp(-1.0, 1.0);
                final double scale = 1 -
                    (1 - Tokens.carouselNeighborScale) * clamped.abs();
                final double opacity = 1 -
                    (1 - Tokens.carouselNeighborOpacity) * clamped.abs();

                return Opacity(
                  opacity: opacity,
                  child: Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()
                      ..setEntry(3, 2, Tokens.carouselPerspective)
                      ..rotateY(Tokens.carouselNeighborRotateY * clamped),
                    child: Transform.scale(
                      scale: scale,
                      child: child,
                    ),
                  ),
                );
              },
              child: Center(
                child: AnimatedScale(
                  scale: index == state.index
                      ? (state.isPlaying
                          ? Tokens.artworkPlayingScale
                          : Tokens.artworkPausedScale)
                      : Tokens.artworkPlayingScale,
                  duration: Tokens.dPageChange,
                  curve: Tokens.curveSpring,
                  child: ArtTile(
                    size: artSize,
                    radius: Tokens.rLarge,
                    image: artwork(track.artworkUrl),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
