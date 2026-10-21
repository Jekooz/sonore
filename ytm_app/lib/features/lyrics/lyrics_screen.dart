import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../audio/playback_controller.dart';
import '../../audio/playback_state.dart';
import '../../audio/track.dart';
import '../../core/app_settings.dart';
import '../../data/models.dart';
import '../../routing/destinations.dart';
import '../../theme/icons.dart';
import '../../theme/tokens.dart';
import '../../ui/data_states.dart';
import '../../ui/screen_header.dart';
import '../../ui/screen_states.dart';
import 'lyrics_controller.dart';

/// Lyrics for the current track.
///
/// Everything here comes from the sidecar's `/lyrics/{videoId}`. When the
/// provider supplied timestamps the screen follows playback and taps seek;
/// when it did not, the same screen renders static lyrics — it never invents a
/// timing to make the following behaviour look supported.
class LyricsScreen extends ConsumerWidget {
  const LyricsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? track = ref.watch(
      playbackProvider.select((PlaybackState state) => state.current),
    );

    return Scaffold(
      backgroundColor: Tokens.transparent,
      body: SafeArea(
        child: track == null
            ? const _NoTrack()
            : ConnectionGate(child: _LyricsBody(track: track)),
      ),
    );
  }
}

class _NoTrack extends StatelessWidget {
  const _NoTrack();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        ScreenHeader(
          title: 'Lyrics',
          onBack: () => context.go(AppDestination.nowPlaying.path),
        ),
        Expanded(
          child: StateMessage(
            message: 'Nothing is playing.',
            footnote: 'Lyrics follow the current track, so start one first.',
            actionLabel: 'Browse library',
            actionIcon: AppIcons.listBullets,
            onAction: () => context.go(AppDestination.library.path),
          ),
        ),
      ],
    );
  }
}

class _LyricsBody extends ConsumerWidget {
  const _LyricsBody({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<LyricsResult?> lyrics = ref.watch(lyricsProvider);

    return Column(
      children: <Widget>[
        ScreenHeader(
          title: track.title,
          onBack: () => context.go(AppDestination.nowPlaying.path),
          trailing: lyrics.value == null
              ? null
              : Semantics(
                  button: true,
                  label: 'Back to Now Playing',
                  child: IconButton(
                    icon: const Icon(
                      AppIcons.musicNotes,
                      size: Tokens.iconSize,
                      color: Tokens.text,
                    ),
                    tooltip: 'Now Playing',
                    onPressed: () => context.go(AppDestination.nowPlaying.path),
                  ),
                ),
        ),
        Expanded(
          child: DataStateView<LyricsResult?>(
            value: lyrics,
            onRetry: () => ref.invalidate(lyricsProvider),
            loading: const _LyricsSkeleton(),
            // The service answers 404 for "none", which the repository turns
            // into null, so "no lyrics" is a state rather than an error.
            isEmpty: (LyricsResult? data) => data == null,
            emptyMessage: 'No lyrics for this track.',
            emptyFootnote:
                'YouTube Music does not publish lyrics for every song. '
                'Everything else about this track still plays normally.',
            data: (LyricsResult? data) => _LyricsList(result: data!),
          ),
        ),
      ],
    );
  }
}

class _LyricsSkeleton extends StatelessWidget {
  const _LyricsSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(
        horizontal: Tokens.pageMarginPhone,
        vertical: Tokens.s16,
      ),
      itemCount: 12,
      itemBuilder: (BuildContext context, int index) => Padding(
        padding: const EdgeInsets.only(bottom: Tokens.s16),
        child: Skeleton(
          // Varying widths read as lines of different length, not as a grid.
          width: 120.0 + (index % 4) * 60,
          height: Tokens.s16,
        ),
      ),
    );
  }
}

/// The lyrics themselves: static when the provider gave no timings, and
/// following playback when it did.
class _LyricsList extends ConsumerStatefulWidget {
  const _LyricsList({required this.result});

  final LyricsResult result;

  @override
  ConsumerState<_LyricsList> createState() => _LyricsListState();
}

class _LyricsListState extends ConsumerState<_LyricsList> {
  final ScrollController _scroll = ScrollController();

  /// One key per line so the current line can be scrolled to exactly, whatever
  /// its height turns out to be after text scaling.
  final Map<int, GlobalKey> _keys = <int, GlobalKey>{};

  int _lastScrolledTo = -1;

  /// Set false when the reader scrolls by hand, so the view stops yanking the
  /// page back until they ask for it again.
  bool _following = true;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  GlobalKey _keyFor(int index) => _keys.putIfAbsent(index, () => GlobalKey());

  /// Index of the line the player is inside, or -1 before the first one.
  int _indexOf(Duration position, List<LyricsLine> lines) {
    int index = -1;
    for (int i = 0; i < lines.length; i++) {
      final Duration? start = lines[i].start;
      if (start == null) return -1;
      if (start <= position) {
        index = i;
      } else {
        break;
      }
    }
    return index;
  }

  void _scrollTo(int index) {
    final BuildContext? target = _keys[index]?.currentContext;
    if (target == null) return;
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    Scrollable.ensureVisible(
      target,
      duration: reduceMotion ? Duration.zero : Tokens.dAmbientCrossfade,
      curve: Curves.easeOut,
      alignment: 0.25,
    );
  }

  @override
  Widget build(BuildContext context) {
    final LyricsResult result = widget.result;
    final List<LyricsLine> lines = result.lines;

    final PlaybackState playback = ref.watch(playbackProvider);
    final bool autoFollowPreference = ref.watch(
      appSettingsProvider.select(
        (AppSettings settings) => settings.lyricsAutoFollow,
      ),
    );

    // Only genuine timings can drive a following view.
    final bool canFollow = result.synced && autoFollowPreference && _following;
    final int index = canFollow ? _indexOf(playback.position, lines) : -1;

    if (index != _lastScrolledTo) {
      _lastScrolledTo = index;
      if (index >= 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _lastScrolledTo == index) _scrollTo(index);
        });
      }
    }

    return NotificationListener<ScrollNotification>(
      // A drag (not the programmatic follow) hands control back to the reader.
      onNotification: (ScrollNotification notification) {
        if (notification is ScrollStartNotification &&
            notification.dragDetails != null &&
            _following) {
          setState(() => _following = false);
        }
        return false;
      },
      child: Column(
        children: <Widget>[
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.symmetric(
                horizontal: Tokens.pageMarginPhone,
                vertical: Tokens.s24,
              ),
              itemCount: lines.length,
              itemBuilder: (BuildContext context, int i) => _LyricLineTile(
                key: _keyFor(i),
                line: lines[i],
                current: i == index,
                // A timed line is a seek target; a static one is text, and
                // offering to seek to a time that does not exist would lie.
                onSeek: lines[i].start == null
                    ? null
                    : () => ref
                          .read(playbackProvider.notifier)
                          .seek(lines[i].start!),
              ),
            ),
          ),
          if (result.source != null)
            Padding(
              padding: const EdgeInsets.only(
                left: Tokens.pageMarginPhone,
                right: Tokens.pageMarginPhone,
                bottom: Tokens.s16,
              ),
              child: Text(
                result.source!,
                style: Tokens.caption,
                textAlign: TextAlign.center,
              ),
            ),
          if (result.synced && !canFollow)
            Padding(
              padding: const EdgeInsets.only(bottom: Tokens.s16),
              child: TextButton.icon(
                icon: const Icon(
                  AppIcons.arrowClockwise,
                  size: Tokens.iconSize,
                  color: Tokens.text,
                ),
                label: const Text(
                  'Back to current line',
                  style: Tokens.rowTitle,
                ),
                onPressed: () => setState(() => _following = true),
              ),
            ),
        ],
      ),
    );
  }
}

class _LyricLineTile extends StatelessWidget {
  const _LyricLineTile({
    super.key,
    required this.line,
    required this.current,
    required this.onSeek,
  });

  final LyricsLine line;
  final bool current;
  final VoidCallback? onSeek;

  @override
  Widget build(BuildContext context) {
    final Widget text = Text(
      line.text,
      style: (current ? Tokens.nowPlayingTitle : Tokens.subtitle).copyWith(
        color: current ? Tokens.text : Tokens.textMuted,
      ),
    );

    if (onSeek == null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: Tokens.s12),
        child: text,
      );
    }

    return Semantics(
      button: true,
      label: 'Go to ${line.text}',
      child: InkWell(
        onTap: onSeek,
        borderRadius: Tokens.rSmallBorder,
        child: Padding(
          padding: const EdgeInsets.only(bottom: Tokens.s12),
          child: text,
        ),
      ),
    );
  }
}
