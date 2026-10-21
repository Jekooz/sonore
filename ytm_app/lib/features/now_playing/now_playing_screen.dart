import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../audio/playback_controller.dart';
import '../../audio/playback_state.dart';
import '../../audio/track.dart';
import '../../routing/destinations.dart';
import '../../theme/icons.dart';
import '../../theme/tokens.dart';
import '../../ui/format.dart';
import '../../ui/pill_button.dart';
import '../../ui/screen_states.dart';
import '../../ui/seek_bar.dart';
import 'artwork.dart';
import 'queue_carousel.dart';
import 'queue_panel.dart';
import 'transport_pill.dart';

/// Now Playing, the primary experience.
///
/// Every size shows the fan carousel of the queue as its centre; desktop adds
/// the Up Next panel on the right. The ambient wash behind everything comes only
/// from the current artwork.
///
/// It renders whatever the shared playback state says. In this phase no audio
/// engine is attached, so in the shipped app the player is empty and this
/// screen shows its empty state — recorded in `proof/phase3.txt`.
class NowPlayingScreen extends ConsumerStatefulWidget {
  const NowPlayingScreen({super.key});

  @override
  ConsumerState<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends ConsumerState<NowPlayingScreen> {
  bool _initialised = false;
  bool _showQueue = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialised) return;
    _initialised = true;
    // Desktop shows the queue panel by default; the queue action toggles it.
    _showQueue = MediaQuery.sizeOf(context).width >= Tokens.breakpointDesktop;
  }

  @override
  Widget build(BuildContext context) {
    final PlaybackState state = ref.watch(playbackProvider);
    final bool isDesktop =
        MediaQuery.sizeOf(context).width >= Tokens.breakpointDesktop;

    // The skeleton is for having nothing to show yet. Changing track already
    // knows the new title and artwork from the queue, so a skip must not blank
    // the screen — the seek bar simply stays inert until the duration arrives.
    if (state.isLoading && !state.hasTrack) {
      return const _NowPlayingSkeleton();
    }

    if (state.error != null) {
      return StateMessage(
        message: state.error!,
        actionLabel: 'Retry',
        actionIcon: AppIcons.arrowClockwise,
        // Retry re-requests the stream rather than only clearing the message:
        // the failure is usually an expired URL or a restarting sidecar.
        onAction: () => ref.read(playbackProvider.notifier).retryLoad(),
      );
    }

    final Track? track = state.current;
    if (track == null) {
      return StateMessage(
        message: 'Nothing is playing yet.',
        footnote: 'Pick something from your library to start listening.',
        actionLabel: 'Browse library',
        actionIcon: AppIcons.listBullets,
        onAction: () => context.go(AppDestination.library.path),
      );
    }

    final AmbientPaletteLoader palette =
        ref.watch(ambientPaletteLoaderProvider);

    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: _AmbientBackground(
            url: track.artworkUrl,
            loader: palette,
          ),
        ),
        SafeArea(
          child: isDesktop
              ? _desktopLayout(state, track)
              : _compactLayout(state, track),
        ),
      ],
    );
  }

  Widget _compactLayout(
    PlaybackState state,
    Track track,
  ) {
    return Column(
      children: <Widget>[
        const Expanded(child: QueueCarousel()),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Tokens.pageMarginPhone,
          ),
          child: Column(
            children: <Widget>[
              Text(
                track.title,
                style: Tokens.nowPlayingTitle,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: Tokens.s4),
              Text(
                track.subtitle,
                style: Tokens.subtitle,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: Tokens.s16),
              _SeekRow(state: state),
              const SizedBox(height: Tokens.s16),
              const TransportPill(),
              const SizedBox(height: Tokens.s12),
              _ActionRow(
                track: track,
                queueVisible: _showQueue,
                // Compact layouts have no room for the panel, so the Queue
                // action opens the dedicated screen instead of toggling
                // something that is not on screen.
                onToggleQueue: () => context.go('/now-playing/queue'),
              ),
              const SizedBox(height: Tokens.s24),
            ],
          ),
        ),
      ],
    );
  }

  Widget _desktopLayout(PlaybackState state, Track track) {
    return Row(
      children: <Widget>[
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Tokens.pageMarginDesktop),
            child: Column(
              children: <Widget>[
                // The same fan carousel the compact layout uses: on desktop the
                // centre is the queue too, with the panel beside it rather than
                // a single lone cover.
                SizedBox(
                  height: Tokens.artworkMaxPhone + Tokens.s48,
                  child: const QueueCarousel(),
                ),
                const SizedBox(height: Tokens.s32),
                Text(
                  track.title,
                  style: Tokens.nowPlayingTitle,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: Tokens.s4),
                Text(
                  track.subtitle,
                  style: Tokens.subtitle,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: Tokens.s24),
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: Tokens.transportMaxWidth,
                  ),
                  child: Column(
                    children: <Widget>[
                      _SeekRow(state: state),
                      const SizedBox(height: Tokens.s24),
                      const TransportPill(),
                      const SizedBox(height: Tokens.s16),
                      _ActionRow(
                        track: track,
                        queueVisible: _showQueue,
                        onToggleQueue: () =>
                            setState(() => _showQueue = !_showQueue),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_showQueue)
          const Padding(
            padding: EdgeInsets.only(
              top: Tokens.s16,
              right: Tokens.s16,
              bottom: Tokens.s16,
            ),
            child: QueuePanel(),
          ),
      ],
    );
  }
}

/// Loads the artwork palette and cross-fades the wash when the track changes.
class _AmbientBackground extends StatefulWidget {
  const _AmbientBackground({required this.url, required this.loader});

  final String? url;
  final AmbientPaletteLoader loader;

  @override
  State<_AmbientBackground> createState() => _AmbientBackgroundState();
}

class _AmbientBackgroundState extends State<_AmbientBackground> {
  List<Color> _colors = const <Color>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _AmbientBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) _load();
  }

  Future<void> _load() async {
    final String? url = widget.url;
    if (url == null || url.isEmpty) {
      if (mounted) setState(() => _colors = const <Color>[]);
      return;
    }
    final List<Color> colors = await widget.loader(url);
    if (!mounted || widget.url != url) return;
    setState(() => _colors = colors);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: Tokens.dAmbientCrossfade,
      child: AmbientBackground(
        key: ValueKey<String>(widget.url ?? ''),
        colors: _colors,
      ),
    );
  }
}

class _SeekRow extends ConsumerWidget {
  const _SeekRow({required this.state});

  final PlaybackState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool canSeek = state.canSeek;
    final PlaybackController controller = ref.read(playbackProvider.notifier);

    return Row(
      children: <Widget>[
        SizedBox(
          width: Tokens.s48,
          child: Text(
            formatDuration(canSeek ? state.position : null),
            style: Tokens.caption,
            textAlign: TextAlign.right,
          ),
        ),
        const SizedBox(width: Tokens.s12),
        Expanded(
          child: SeekBar(
            position: state.position,
            duration: canSeek ? state.duration : Duration.zero,
            buffered: state.buffered,
            enabled: canSeek,
            onSeek: controller.seek,
            onSeekEnd: controller.seek,
          ),
        ),
        const SizedBox(width: Tokens.s12),
        SizedBox(
          width: Tokens.s48,
          child: Text(
            formatDuration(canSeek ? state.duration : null),
            style: Tokens.caption,
          ),
        ),
      ],
    );
  }
}

class _ActionRow extends ConsumerWidget {
  const _ActionRow({
    required this.track,
    required this.queueVisible,
    required this.onToggleQueue,
  });

  final Track track;
  final bool queueVisible;
  final VoidCallback onToggleQueue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlaybackController controller = ref.read(playbackProvider.notifier);

    return Wrap(
      alignment: WrapAlignment.center,
      spacing: Tokens.s12,
      runSpacing: Tokens.s12,
      children: <Widget>[
        PillButton(
          icon: track.isLiked ? AppIcons.heartFill : AppIcons.heart,
          isActive: track.isLiked,
          label: 'Like',
          onPressed: controller.toggleLike,
        ),
        PillButton(
          icon: AppIcons.queue,
          isActive: queueVisible,
          label: 'Queue',
          onPressed: onToggleQueue,
        ),
        // Design.md section J: the Now Playing bar menu offers lyrics and EQ. They
        // open as real pages, not popups, so the spec's "not tiny desktop-style
        // popups" rule holds at every size.
        PillButton(
          icon: AppIcons.textAa,
          label: 'Lyrics',
          onPressed: () => context.go('/now-playing/lyrics'),
        ),
        PillButton(
          icon: AppIcons.faders,
          label: 'EQ',
          onPressed: () => context.go('/now-playing/equalizer'),
        ),
      ],
    );
  }
}

class _NowPlayingSkeleton extends StatelessWidget {
  const _NowPlayingSkeleton();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const <Widget>[
            Skeleton(
              width: Tokens.artworkMaxPhone,
              height: Tokens.artworkMaxPhone,
              radius: Tokens.rLarge,
            ),
            SizedBox(height: Tokens.s24),
            Skeleton(width: Tokens.s48 * 4, height: Tokens.s24),
            SizedBox(height: Tokens.s12),
            Skeleton(width: Tokens.s48 * 3, height: Tokens.s16),
          ],
        ),
      ),
    );
  }
}
