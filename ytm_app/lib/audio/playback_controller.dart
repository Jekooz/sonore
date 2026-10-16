import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_settings.dart';
import '../theme/tokens.dart';
import 'playback_state.dart';
import 'track.dart';

/// Reorders the tracks that have not played yet when shuffle is switched on.
///
/// A seam, not indirection for its own sake: the default is a real
/// Fisher-Yates shuffle, and a test overrides it so an assertion about play
/// order is deterministic instead of lucky.
typedef ShuffleFn = List<Track> Function(List<Track> tracks);

final Provider<ShuffleFn> shuffleProvider = Provider<ShuffleFn>((Ref ref) {
  return (List<Track> tracks) {
    final List<Track> out = List<Track>.of(tracks);
    final Random random = Random();
    for (int i = out.length - 1; i > 0; i--) {
      final int j = random.nextInt(i + 1);
      final Track swap = out[i];
      out[i] = out[j];
      out[j] = swap;
    }
    return out;
  };
});

/// The single playback/queue state for the whole app.
///
/// This is the one authority for *what* should be playing: queue, index, repeat,
/// shuffle, like state and the seek the user committed. It deliberately holds no
/// reference to an audio engine — `playback_service.dart` watches this state and
/// drives the engine to match it, so the engine can be swapped or faked without
/// this class changing.
///
/// Two fields make that contract explicit: [PlaybackState.loadToken] (load the
/// current track) and [PlaybackState.seekToken] (apply [PlaybackState.seekRequest]).
/// Both are commands consumed exactly once by the engine watch.
class PlaybackController extends Notifier<PlaybackState> {
  /// The collection order as it was when shuffle was switched on, so switching
  /// it off restores what the user actually built. Null while shuffle is off,
  /// and dropped whenever the queue is edited: an edit is the newer instruction,
  /// so the order the user sees after it is the one that stays.
  List<Track>? _unshuffled;

  @override
  PlaybackState build() {
    // Read, never watch: a settings write must not rebuild this notifier and
    // throw the queue away. The three persisted player modes seed from here.
    final AppSettings settings = ref.read(appSettingsProvider);

    // A reset from the Settings screen (or any other future writer) has to move
    // the transport too, or the toggle and the sound would disagree.
    ref.listen<AppSettings>(appSettingsProvider, (
      AppSettings? previous,
      AppSettings next,
    ) {
      if (previous == null) return;
      if (next.shuffle != state.shuffle) {
        _setShuffle(next.shuffle, persist: false);
      }
      if (next.repeatMode != state.repeat || next.autoplay != state.autoplay) {
        state = state.copyWith(
          repeat: next.repeatMode,
          autoplay: next.autoplay,
        );
      }
    });

    return PlaybackState(
      repeat: settings.repeatMode,
      shuffle: settings.shuffle,
      autoplay: settings.autoplay,
    );
  }

  /// Loads a queue and starts at [startIndex]. This is the queue entry point for
  /// the real playback layer: Home, Search and Library selection all route
  /// through it, and every one of them plays through the same engine.
  void setQueue(List<Track> tracks, {int startIndex = 0}) {
    if (tracks.isEmpty) {
      // Bump the token rather than resetting it: the audio layer unloads the
      // engine when the load token changes and there is no track left.
      clear();
      return;
    }
    // A new collection replaces the shuffled order rather than being restored
    // to it: the seed of the shuffle is gone.
    _unshuffled = null;
    final int start = startIndex.clamp(0, tracks.length - 1);
    // With shuffle on the track the user chose still plays first — it is what
    // they asked for — and the rest of the collection is the surprise.
    final List<Track> queue = state.shuffle && tracks.length > 1
        ? <Track>[
            tracks[start],
            ..._shuffle(<Track>[
              ...tracks.sublist(0, start),
              ...tracks.sublist(start + 1),
            ]),
          ]
        : tracks;
    state = PlaybackState(
      queue: List<Track>.unmodifiable(queue),
      index: state.shuffle ? 0 : start,
      isPlaying: true,
      // Player modes persist across queue changes (spec: shuffle persists).
      repeat: state.repeat,
      shuffle: state.shuffle,
      autoplay: state.autoplay,
      loadToken: state.loadToken + 1,
    );
  }

  List<Track> _shuffle(List<Track> tracks) => ref.read(shuffleProvider)(tracks);

  /// The id of the current track, or null when nothing is queued.
  String? get currentTrackId => state.current?.id;

  /// Plays [track] inside [context]: that list becomes the queue and [track] is
  /// where it starts. This is the spec's row rule — "that row becomes the queue,
  /// starting at that row" — and every list in the app goes through it, so a
  /// row click never plays from a one-track queue of its own.
  void playFromContext(List<Track> context, Track track) {
    final int index = context.indexWhere((Track entry) => entry.id == track.id);
    setQueue(context, startIndex: index < 0 ? 0 : index);
  }

  /// Inserts [tracks] directly after the current one without discarding the rest
  /// of the queue (spec: context menu "Play next").
  void playNext(List<Track> tracks) {
    if (tracks.isEmpty) return;
    if (!state.hasTrack) {
      setQueue(tracks);
      return;
    }
    _unshuffled = null;
    final List<Track> queue = List<Track>.of(state.queue);
    queue.insertAll(state.index + 1, tracks);
    state = state.copyWith(queue: List<Track>.unmodifiable(queue));
  }

  /// Moves the track at [from] to [to] (spec section F: "Drag handles reorder
  /// tracks"). The current track follows wherever it is moved to, so the queue
  /// screen can reorder freely without the audio changing.
  void move(int from, int to) {
    final int length = state.queue.length;
    if (from < 0 || from >= length) return;
    final int target = to.clamp(0, length - 1);
    if (from == target) return;

    _unshuffled = null;
    final List<Track> queue = List<Track>.of(state.queue);
    final Track moved = queue.removeAt(from);
    queue.insert(target, moved);

    int index = state.index;
    if (index == from) {
      index = target;
    } else if (from < index && target >= index) {
      index -= 1;
    } else if (from > index && target <= index) {
      index += 1;
    }
    state = state.copyWith(queue: List<Track>.unmodifiable(queue), index: index);
  }

  /// Appends [tracks] to the end of the queue (spec: "Add to queue"). When
  /// nothing is playing this starts them, so the action never silently no-ops.
  void addToQueue(List<Track> tracks) {
    if (tracks.isEmpty) return;
    if (!state.hasTrack) {
      setQueue(tracks);
      return;
    }
    _unshuffled = null;
    final List<Track> queue = List<Track>.of(state.queue)..addAll(tracks);
    state = state.copyWith(queue: List<Track>.unmodifiable(queue));
  }

  /// Removes the track at [index]; the current index follows its track.
  void removeAt(int index) {
    if (index < 0 || index >= state.queue.length) return;
    _unshuffled = null;
    final List<Track> queue = List<Track>.of(state.queue)..removeAt(index);
    if (queue.isEmpty) {
      clear();
      return;
    }
    final int nextIndex = index < state.index
        ? state.index - 1
        : state.index.clamp(0, queue.length - 1);
    final bool reload = index == state.index;
    state = state.copyWith(
      queue: List<Track>.unmodifiable(queue),
      index: nextIndex,
      loadToken: reload ? state.loadToken + 1 : state.loadToken,
      position: reload ? Duration.zero : state.position,
      // The removed track's length is not the new track's length.
      clearReportedDuration: reload,
    );
  }

  void clear() {
    _unshuffled = null;
    state = PlaybackState(
      repeat: state.repeat,
      shuffle: state.shuffle,
      autoplay: state.autoplay,
      loadToken: state.loadToken + 1,
    );
  }

  void playAt(int index) {
    if (index < 0 || index >= state.queue.length) return;
    state = state.copyWith(
      index: index,
      isPlaying: true,
      position: Duration.zero,
      buffered: Duration.zero,
      // Until the engine reports this track's own length, the bar and the time
      // labels fall back to the track's metadata duration — never to whatever
      // the track before it happened to be.
      clearReportedDuration: true,
      clearError: true,
      loadToken: state.loadToken + 1,
    );
  }

  void togglePlayPause() {
    if (!state.hasTrack) return;
    state = state.copyWith(isPlaying: !state.isPlaying);
  }

  /// Advances through the queue; respects repeat (spec: transport controls).
  void next() {
    if (!state.hasTrack) return;

    if (state.repeat == RepeatMode.one) {
      // The same track plays again from the top, which is a reload rather than
      // a move: bumping the load token is what actually restarts the audio.
      state = state.copyWith(
        position: Duration.zero,
        isPlaying: true,
        loadToken: state.loadToken + 1,
      );
      return;
    }

    if (state.index < state.queue.length - 1) {
      playAt(state.index + 1);
      return;
    }

    if (state.repeat == RepeatMode.all) {
      playAt(0);
      return;
    }

    // End of the queue with repeat off: stop rather than silently looping.
    state = state.copyWith(isPlaying: false, position: Duration.zero);
  }

  /// The engine reporting that the current media reached its end. Completion
  /// follows exactly the same rules as pressing Next, including Repeat One and
  /// stopping at the end of a repeat-off queue.
  void completeTrack() => next();

  /// Restarts the current track when it is past the threshold, otherwise steps
  /// back one queue item (spec: previous).
  void previous() {
    if (!state.hasTrack) return;

    if (state.position > Tokens.previousRestartThreshold || state.index == 0) {
      if (state.position == Duration.zero) return;
      state = state.copyWith(
        position: Duration.zero,
        seekRequest: Duration.zero,
        seekToken: state.seekToken + 1,
      );
      return;
    }

    playAt(state.index - 1);
  }

  /// Clamps to the known duration and records the seek as a command for the
  /// engine. The UI shows [PlaybackState.position] optimistically and the
  /// engine's next position report reconciles it (spec: scrubber).
  void seek(Duration to) {
    if (!state.canSeek) return;
    final int max = state.duration.inMilliseconds;
    final int clamped = to.inMilliseconds.clamp(0, max);
    final Duration target = Duration(milliseconds: clamped);
    state = state.copyWith(
      position: target,
      seekRequest: target,
      seekToken: state.seekToken + 1,
    );
  }

  /// Called by the audio engine as playback advances. This is the engine hook the
  /// real playback layer drives; it never touches the command tokens.
  void reportProgress({
    Duration? position,
    Duration? buffered,
    Duration? duration,
  }) {
    if (!state.hasTrack) return;
    state = state.copyWith(
      position: position ?? state.position,
      buffered: buffered ?? state.buffered,
      reportedDuration: duration ?? state.reportedDuration,
    );
  }

  /// The engine stopped producing audio without the app asking. Keeps the
  /// play/pause control truthful (spec: "Always reflects the real playback
  /// state").
  void reportPaused() {
    if (!state.isPlaying) return;
    state = state.copyWith(isPlaying: false);
  }

  /// Marks a track as loading while its stream URL is being resolved.
  void reportLoading(bool value) {
    if (state.isLoading == value) return;
    state = state.copyWith(isLoading: value);
  }

  /// Retries the current track after a failure: clears the message and re-issues
  /// the load command so the engine is asked again for a fresh stream URL.
  ///
  /// A retry is not a no-op "clear the error" button — resolution failures are
  /// usually transient (an expired signed URL, a sidecar that was restarting),
  /// so the action that makes the screen useful is loading again.
  void retryLoad() {
    if (!state.hasTrack || state.isLoading) return;
    state = state.copyWith(
      clearError: true,
      loadToken: state.loadToken + 1,
      position: Duration.zero,
      buffered: Duration.zero,
      clearReportedDuration: true,
      isPlaying: true,
    );
  }

  void toggleLike() {
    if (!state.hasTrack) return;
    final List<Track> queue = List<Track>.of(state.queue);
    final Track current = queue[state.index];
    queue[state.index] = current.copyWith(isLiked: !current.isLiked);
    state = state.copyWith(queue: List<Track>.unmodifiable(queue));
  }

  /// Turns shuffle on or off and reorders playback accordingly (spec: "Shuffle
  /// | Toggle persists and changes queue selection").
  void setShuffle(bool value) => _setShuffle(value, persist: true);

  void _setShuffle(bool value, {required bool persist}) {
    if (state.shuffle == value) return;

    if (!value) {
      // Restore the order from before shuffle, keeping the same track current.
      final List<Track>? original = _unshuffled;
      _unshuffled = null;
      if (original != null && state.hasTrack) {
        final int index = original.indexWhere(
          (Track track) => track.id == state.current!.id,
        );
        state = state.copyWith(
          queue: List<Track>.unmodifiable(original),
          index: index < 0 ? state.index : index,
          shuffle: false,
        );
      } else {
        state = state.copyWith(shuffle: false);
      }
      if (persist) _persistModes();
      return;
    }

    final List<Track> upcoming = state.upNext;
    if (!state.hasTrack || upcoming.length < 2) {
      // Nothing to shuffle yet; the mode still persists and the order is
      // applied when a queue with more than one upcoming track arrives.
      state = state.copyWith(shuffle: true);
      if (persist) _persistModes();
      return;
    }

    _unshuffled = state.queue;
    final List<Track> shuffled = _shuffle(upcoming);
    state = state.copyWith(
      queue: List<Track>.unmodifiable(<Track>[
        ...state.queue.sublist(0, state.index + 1),
        ...shuffled,
      ]),
      shuffle: true,
    );
    if (persist) _persistModes();
  }

  void cycleRepeat() {
    state = state.copyWith(repeat: state.repeat.next);
    _persistModes();
  }

  /// Autoplay is the queue refilling itself when it runs out (spec section F).
  /// Persisted like the other player modes, so the setting and the toggle in
  /// the queue screen always agree.
  void setAutoplay(bool value) {
    if (state.autoplay == value) return;
    state = state.copyWith(autoplay: value);
    _persistModes();
  }

  /// Writes the three player modes back to the store that owns them across
  /// runs. A store failure is reported by the Settings save status rather than
  /// breaking playback.
  void _persistModes() {
    ref.read(appSettingsProvider.notifier).setPlayerModes(
          repeat: state.repeat,
          shuffle: state.shuffle,
          autoplay: state.autoplay,
        );
  }

  void reportError(String? message) => state = message == null
      ? state.copyWith(clearError: true)
      : state.copyWith(error: message);
}

final NotifierProvider<PlaybackController, PlaybackState> playbackProvider =
    NotifierProvider<PlaybackController, PlaybackState>(
  PlaybackController.new,
);
