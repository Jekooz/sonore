import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../../ui/screen_states.dart';
import '../../ui/seek_bar.dart';
import 'artwork.dart';
import 'lyrics_panel.dart';
import 'queue_panel.dart';
import 'transport_pill.dart';

/// Which on-demand panel is open, if any. Opening one closes the other:
/// two overlays at once would be exactly the clutter the design bans.
enum _NowPlayingPanel { none, queue, lyrics }

/// Now Playing, the primary experience.
///
/// One centered column: the artwork sized to the leftover viewport, then
/// title, artist, seek row, transport and one icon-only row of secondary
/// actions. Nothing scrolls and nothing wraps; every block is a fixed,
/// compact height except the artwork, which absorbs whatever remains.
///
/// Queue and Lyrics are panels that slide in on demand — desktop from the
/// right edge, phone as a bottom sheet — with a tap-outside barrier, an Esc
/// handler and a mirrored state on the icon that opened them. The equalizer
/// is not here: it belongs to Settings.
class NowPlayingScreen extends ConsumerStatefulWidget {
  const NowPlayingScreen({super.key});

  @override
  ConsumerState<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends ConsumerState<NowPlayingScreen> {
  _NowPlayingPanel _panel = _NowPlayingPanel.none;
  final FocusNode _escapeNode = FocusNode(skipTraversal: true);

  @override
  void dispose() {
    _escapeNode.dispose();
    super.dispose();
  }

  void _setPanel(_NowPlayingPanel panel) {
    setState(() => _panel = panel);
    // Esc needs a focused node to fire through; claim it while a panel is
    // open, hand it back otherwise.
    if (panel == _NowPlayingPanel.none) {
      _escapeNode.unfocus();
    } else {
      _escapeNode.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final PlaybackState state = ref.watch(playbackProvider);

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

    return SafeArea(
      top: false,
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape):
              () => _setPanel(_NowPlayingPanel.none),
        },
        child: Focus(
          focusNode: _escapeNode,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final bool wide =
                  constraints.maxWidth >= Tokens.breakpointDesktop;
              final bool panelOpen = _panel != _NowPlayingPanel.none;

              return Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  _PlayerColumn(
                    state: state,
                    track: track,
                    panel: _panel,
                    onPanel: _setPanel,
                  ),

                  // The barrier dims the page and makes "tap outside" real.
                  AnimatedOpacity(
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : Tokens.dFadeIn,
                    opacity: panelOpen ? 1 : 0,
                    child: IgnorePointer(
                      ignoring: !panelOpen,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _setPanel(_NowPlayingPanel.none),
                        child: const ColoredBox(color: Tokens.panelScrim),
                      ),
                    ),
                  ),

                  // Panels are mounted only while open, each with its own
                  // slide-in; switching between them restarts the motion.
                  if (_panel == _NowPlayingPanel.queue)
                    wide
                        ? _SidePanel(
                            key: const ValueKey<String>('queue'),
                            child: const QueuePanel(),
                          )
                        : _BottomPanel(
                            key: const ValueKey<String>('queue'),
                            onDismiss: () => _setPanel(_NowPlayingPanel.none),
                            child: const QueuePanel(),
                          ),
                  if (_panel == _NowPlayingPanel.lyrics)
                    wide
                        ? _SidePanel(
                            key: const ValueKey<String>('lyrics'),
                            child: const LyricsPanel(),
                          )
                        : _BottomPanel(
                            key: const ValueKey<String>('lyrics'),
                            onDismiss: () => _setPanel(_NowPlayingPanel.none),
                            child: const LyricsPanel(),
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

/// The playing column. Centered inside [Tokens.contentMaxWidth]; the artwork
/// takes whatever height the fixed controls leave, capped by
/// [Tokens.artworkMaxDesktop], and the control block keeps its own compact,
/// fixed heights — which is what keeps the screen scroll-free at every size.
class _PlayerColumn extends ConsumerWidget {
  const _PlayerColumn({
    required this.state,
    required this.track,
    required this.panel,
    required this.onPanel,
  });

  final PlaybackState state;
  final Track track;
  final _NowPlayingPanel panel;
  final ValueChanged<_NowPlayingPanel> onPanel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ArtworkResolver artwork = ref.watch(artworkResolverProvider);
    final PlaybackController controller = ref.read(playbackProvider.notifier);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: Tokens.contentMaxWidth),
        child: Column(
          children: <Widget>[
            // Artwork: elastic, capped, centered. Size = the smaller of the
            // leftover width and the leftover height, so it can never push
            // the control block out of the viewport.
            Flexible(
              child: Center(
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints c) {
                    final double side = math.min(
                      math.min(
                        c.maxWidth - Tokens.s48,
                        c.maxHeight - Tokens.s24,
                      ),
                      Tokens.artworkMaxDesktop,
                    ).clamp(Tokens.s16, Tokens.artworkMaxDesktop);
                    return ArtTile(
                      size: side.isFinite ? side : Tokens.s16,
                      radius: Tokens.rLarge,
                      image: artwork(track.artworkUrl),
                    );
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Tokens.s24,
                Tokens.s16,
                Tokens.s24,
                0,
              ),
              child: Column(
                children: <Widget>[
                  Text(
                    track.title,
                    style: Tokens.nowPlayingTitle,
                    textAlign: TextAlign.center,
                    maxLines: 1,
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
                ],
              ),
            ),
            // Transport, seek and secondary actions share one centered column
            // that never widens beyond the transport cap on a wide window.
            ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: Tokens.transportMaxWidth,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Tokens.s16),
                child: Column(
                  children: <Widget>[
                    const SizedBox(height: Tokens.s16),
                    _SeekRow(state: state),
                    const SizedBox(height: Tokens.s16),
                    const TransportPill(),
                    const SizedBox(height: Tokens.s12),
                    _SecondaryActions(
                      track: track,
                      panel: panel,
                      onPanel: onPanel,
                      onToggleLike: controller.toggleLike,
                    ),
                    const SizedBox(height: Tokens.s24),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Icon-only secondary actions per the minimal design: Like, Lyrics, Queue.
/// Every action carries a [Semantics] label — the visible labels are gone
/// and a screen reader still has to name these.
class _SecondaryActions extends StatelessWidget {
  const _SecondaryActions({
    required this.track,
    required this.panel,
    required this.onPanel,
    required this.onToggleLike,
  });

  final Track track;
  final _NowPlayingPanel panel;
  final ValueChanged<_NowPlayingPanel> onPanel;
  final VoidCallback onToggleLike;

  void _switchPanel(_NowPlayingPanel target) {
    // Tapping the open panel's icon closes it; either icon closes the other
    // panel first, so two overlays can never stack.
    onPanel(panel == target ? _NowPlayingPanel.none : target);
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _IconAction(
          icon: track.isLiked ? AppIcons.heartFill : AppIcons.heart,
          active: track.isLiked,
          label: track.isLiked ? 'Unlike' : 'Like',
          onPressed: onToggleLike,
        ),
        _IconAction(
          icon: AppIcons.textAa,
          active: panel == _NowPlayingPanel.lyrics,
          label: 'Lyrics',
          onPressed: () => _switchPanel(_NowPlayingPanel.lyrics),
        ),
        _IconAction(
          icon: AppIcons.queue,
          active: panel == _NowPlayingPanel.queue,
          label: 'Queue',
          onPressed: () => _switchPanel(_NowPlayingPanel.queue),
        ),
      ],
    );
  }
}

/// An icon-only action button with a [Semantics] label and a raised pill
/// while it is active. Hit area [Tokens.minTouchTarget].
class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.active,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final bool active;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: IconButton(
        tooltip: label,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          foregroundColor: active ? Tokens.text : Tokens.textSecondary,
          backgroundColor: active ? Tokens.surfaceRaised : null,
          minimumSize: const Size.square(Tokens.minTouchTarget),
          fixedSize: const Size.square(Tokens.minTouchTarget),
          padding: EdgeInsets.zero,
          shape: Tokens.shapePill,
          hoverColor: Tokens.glassThin,
          focusColor: Tokens.glassThin,
          highlightColor: Tokens.surfaceRaised,
        ),
        icon: Icon(icon, size: Tokens.iconSize),
      ),
    );
  }
}

/// Seek row: elapsed, scrubber, total. Its own [Consumer] keeps the row from
/// rebuilding the artwork column every playback tick.
class _SeekRow extends StatelessWidget {
  const _SeekRow({required this.state});

  final PlaybackState state;

  @override
  Widget build(BuildContext context) {
    final bool canSeek = state.canSeek;

    return Consumer(
      builder: (BuildContext context, WidgetRef ref, Widget? _) {
        final PlaybackController controller = ref.read(
          playbackProvider.notifier,
        );

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
      },
    );
  }
}

/// Desktop side panel: glass, slid in from the right edge over the page —
/// never a layout column that pushes content around.
class _SidePanel extends StatelessWidget {
  const _SidePanel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final double travel = Tokens.queuePanelWidth + Tokens.s24;

    return Align(
      alignment: AlignmentDirectional.centerEnd,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 1, end: 0),
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : Tokens.dPageChange,
        curve: Tokens.curvePress,
        builder: (BuildContext context, double t, Widget? inner) {
          return Transform.translate(
            offset: Offset(t * travel, 0),
            child: Opacity(
              opacity: (1 - t).clamp(0.0, 1.0),
              child: inner,
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 0, Tokens.s24, Tokens.s24),
          child: SizedBox(
            width: Tokens.queuePanelWidth,
            child: GlassSurface(
              tier: GlassTier.regular,
              radius: Tokens.rLarge,
              child: Material(
                type: MaterialType.transparency,
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Phone bottom sheet: glass, slid in from the bottom, dismissed by the
/// grip strip at its top edge. Bottoms out just above the floating
/// navigation pill, whose zone the shell already clears from the page.
class _BottomPanel extends StatelessWidget {
  const _BottomPanel({super.key, required this.child, required this.onDismiss});

  final Widget child;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Tokens.s16,
        0,
        Tokens.s16,
        Tokens.s16,
      ),
      child: Align(
        alignment: AlignmentDirectional.bottomCenter,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 1, end: 0),
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : Tokens.dPageChange,
          curve: Tokens.curvePress,
          builder: (BuildContext context, double t, Widget? inner) {
            final double travel = MediaQuery.sizeOf(context).height / 2;
            return Transform.translate(
              offset: Offset(0, t * travel),
              child: Opacity(
                opacity: (1 - t).clamp(0.0, 1.0),
                child: inner,
              ),
            );
          },
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final double height = math.min(
                constraints.maxHeight * 0.62,
                Tokens.sheetMaxHeight,
              );
              final double radius = Tokens.rLarge;

              return ClipPath(
                clipper: ShapeBorderClipper(
                  shape: Tokens.shapeFor(radius),
                  textDirection: Directionality.maybeOf(context),
                ),
                child: GlassSurface(
                  tier: GlassTier.regular,
                  radius: radius,
                  child: Material(
                    type: MaterialType.transparency,
                    child: SizedBox(
                      height: height,
                      child: Column(
                        children: <Widget>[
                          // The grip: a visible grabber band. Dragging it down
                          // (or flinging it) dismisses the sheet; the list
                          // below keeps its own scroll unaffected — the
                          // gesture arenas never fight.
                          _SheetGrip(onDismiss: onDismiss),
                          Expanded(
                            child: child,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The grabber: a small pill-shaped bar inside a generous drag band. The
/// dismissal threshold lives in [Tokens.sheetFlingVelocity].
class _SheetGrip extends StatelessWidget {
  const _SheetGrip({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const ValueKey<String>('np-panel-grip'),
      behavior: HitTestBehavior.opaque,
      onVerticalDragEnd: (DragEndDetails details) {
        final double velocity = details.primaryVelocity ?? 0;
        if (velocity > Tokens.sheetFlingVelocity) onDismiss();
      },
      child: SizedBox(
        height: Tokens.s24,
        child: Center(
          child: Container(
            width: Tokens.s48 - 12,
            height: Tokens.s4,
            decoration: ShapeDecoration(
              color: Tokens.textMuted,
              shape: Tokens.shapePill,
            ),
          ),
        ),
      ),
    );
  }
}

/// Loading: the same column shape minus the real data, so a swap never
/// reshuffles the screen.
class _NowPlayingSkeleton extends StatelessWidget {
  const _NowPlayingSkeleton();

  @override
  Widget build(BuildContext context) {
    return const SafeArea(
      top: false,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
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

