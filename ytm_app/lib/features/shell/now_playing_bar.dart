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
import '../../ui/format.dart';
import '../../ui/glass_surface.dart';
import '../../ui/seek_bar.dart';
import '../now_playing/artwork.dart';

/// The persistent Now Playing bar.
///
/// It is floating chrome, like the navigation it hovers above: a thick glass
/// pill that sits clear of the page bottom with its own margins, casting the
/// same soft shadow as every other floating surface. The old progress
/// hairline is now a real — if whisper-thin — scrubber along the pill's
/// bottom edge, so a seek never requires the full page first.
///
/// The bar stays hidden while the queue is empty and on Now Playing itself,
/// where the page is the player.
class NowPlayingBar extends ConsumerWidget {
  const NowPlayingBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlaybackState state = ref.watch(playbackProvider);
    final Track? track = state.current;

    if (track == null) return const SizedBox.shrink();

    final PlaybackController controller = ref.read(playbackProvider.notifier);
    final ArtworkResolver artwork = ref.watch(artworkResolverProvider);

    void openNowPlaying() => context.go(AppDestination.nowPlaying.path);

    return Semantics(
      container: true,
      label: 'Now playing',
      child: GlassSurface(
        tier: GlassTier.thick,
        shape: Tokens.shapePill,
        child: SizedBox(
          height: Tokens.nowPlayingBarHeight,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final bool wide =
                  constraints.maxWidth >= Tokens.breakpointDesktop;
              return Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  // The pill's own interior frame; the scrubber hugs the
                  // bottom edge below this row.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      Tokens.s24,
                      Tokens.s4,
                      Tokens.s24,
                      Tokens.s12,
                    ),
                    child: wide
                        ? _WideContent(
                            state: state,
                            controller: controller,
                            track: track,
                            artwork: artwork,
                            onOpen: openNowPlaying,
                          )
                        : _CompactContent(
                            state: state,
                            controller: controller,
                            track: track,
                            artwork: artwork,
                            onOpen: openNowPlaying,
                          ),
                  ),
                  // A thin, fully interactive scrubber along the bottom edge,
                  // inset past the pill's rounded corners so its ends never
                  // get clipped by the radius.
                  Positioned(
                    left: Tokens.s24,
                    right: Tokens.s24,
                    bottom: Tokens.s8,
                    child: SeekBar(
                      compact: true,
                      position: state.position,
                      duration: state.duration,
                      buffered: state.buffered,
                      onSeekEnd: state.canSeek ? controller.seek : null,
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

/// Track artwork, title and artist. The whole summary is the "open Now Playing"
/// target, with hover/focus states because it is a real control.
class _TrackSummary extends StatelessWidget {
  const _TrackSummary({
    required this.track,
    required this.artwork,
    required this.onOpen,
  });

  final Track track;
  final ArtworkResolver artwork;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onOpen,
        borderRadius: Tokens.rSmallBorder,
        hoverColor: Tokens.glassThick,
        focusColor: Tokens.glassThick,
        splashColor: Tokens.transparent,
        child: Row(
          children: <Widget>[
            ArtTile(
              size: Tokens.artThumbSize,
              radius: Tokens.rSmall,
              image: artwork(track.artworkUrl),
            ),
            const SizedBox(width: Tokens.s12),
            Expanded(
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
          ],
        ),
      ),
    );
  }
}

/// Wide windows: metadata left, transport centred, elapsed/total right. The
/// three zones read as one control set at a glance.
class _WideContent extends StatelessWidget {
  const _WideContent({
    required this.state,
    required this.controller,
    required this.track,
    required this.artwork,
    required this.onOpen,
  });

  final PlaybackState state;
  final PlaybackController controller;
  final Track track;
  final ArtworkResolver artwork;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          flex: 4,
          child: _TrackSummary(track: track, artwork: artwork, onOpen: onOpen),
        ),
        Expanded(
          flex: 5,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: _transportControls(state, controller),
          ),
        ),
        Expanded(
          flex: 3,
          child: Align(
            alignment: Alignment.centerRight,
            child: _TimeReadout(state: state),
          ),
        ),
      ],
    );
  }
}

/// Compact windows: all available width goes to the track, with the three
/// essential controls kept at their full 48 px touch targets.
class _CompactContent extends StatelessWidget {
  const _CompactContent({
    required this.state,
    required this.controller,
    required this.track,
    required this.artwork,
    required this.onOpen,
  });

  final PlaybackState state;
  final PlaybackController controller;
  final Track track;
  final ArtworkResolver artwork;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: _TrackSummary(track: track, artwork: artwork, onOpen: onOpen),
        ),
        const SizedBox(width: Tokens.s8),
        ..._transportControls(state, controller),
      ],
    );
  }
}

List<Widget> _transportControls(
  PlaybackState state,
  PlaybackController controller,
) {
  return <Widget>[
    _BarButton(
      icon: AppIcons.skipBack,
      tooltip: 'Previous',
      onTap: controller.previous,
    ),
    _PlayPauseButton(
      isPlaying: state.isPlaying,
      onTap: controller.togglePlayPause,
    ),
    _BarButton(
      icon: AppIcons.skipForward,
      tooltip: 'Next',
      onTap: controller.next,
    ),
  ];
}

class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      style: IconButton.styleFrom(
        foregroundColor: Tokens.text,
        minimumSize: const Size.square(Tokens.minTouchTarget),
        fixedSize: const Size.square(Tokens.minTouchTarget),
        padding: EdgeInsets.zero,
        hoverColor: Tokens.glassThick,
        focusColor: Tokens.glassThick,
        highlightColor: Tokens.surfaceRaised,
      ),
      icon: Icon(icon, size: Tokens.iconSize),
    );
  }
}

/// The white primary play/pause control: dark glyph on a white circle,
/// monochrome like everything else in the bar.
class _PlayPauseButton extends StatelessWidget {
  const _PlayPauseButton({required this.isPlaying, required this.onTap});

  final bool isPlaying;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: isPlaying ? 'Pause' : 'Play',
      onPressed: onTap,
      style: IconButton.styleFrom(
        backgroundColor: Tokens.text,
        foregroundColor: Tokens.bg,
        minimumSize: const Size.square(Tokens.minTouchTarget),
        fixedSize: const Size.square(Tokens.minTouchTarget),
        padding: EdgeInsets.zero,
        shape: const CircleBorder(),
        hoverColor: Tokens.surfaceRaised,
        focusColor: Tokens.glassThick,
        highlightColor: Tokens.surfaceRaised,
      ),
      icon: Icon(
        isPlaying ? AppIcons.pauseFill : AppIcons.playFill,
        size: Tokens.iconSize,
      ),
    );
  }
}

class _TimeReadout extends StatelessWidget {
  const _TimeReadout({required this.state});

  final PlaybackState state;

  @override
  Widget build(BuildContext context) {
    if (!state.canSeek) return const SizedBox.shrink();

    final String position = formatDuration(state.position);
    final String duration = formatDuration(state.duration);

    return Text(
      '$position / $duration',
      // textSecondary, not the muted caption: the elapsed/total readout is
      // information the reader actually uses while scrubbing.
      style: Tokens.subtitle,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
