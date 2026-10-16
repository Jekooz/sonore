import 'package:flutter/foundation.dart';

import 'track.dart';

/// Repeat cycles Off → Repeat All → Repeat One (spec: transport controls).
enum RepeatMode {
  off,
  all,
  one;

  RepeatMode get next => switch (this) {
        RepeatMode.off => RepeatMode.all,
        RepeatMode.all => RepeatMode.one,
        RepeatMode.one => RepeatMode.off,
      };

  bool get isActive => this != RepeatMode.off;
}

/// Everything the player surfaces render.
///
/// The queue and index are owned here so the mini player, Now Playing, the
/// carousel and the queue panel all read the same source and cannot drift.
@immutable
class PlaybackState {
  const PlaybackState({
    this.queue = const <Track>[],
    this.index = 0,
    this.isPlaying = false,
    this.position = Duration.zero,
    this.buffered = Duration.zero,
    this.reportedDuration,
    this.repeat = RepeatMode.off,
    this.shuffle = false,
    this.autoplay = true,
    this.isLoading = false,
    this.error,
    this.loadToken = 0,
    this.seekToken = 0,
    this.seekRequest = Duration.zero,
  });

  final List<Track> queue;
  final int index;
  final bool isPlaying;
  final Duration position;
  final Duration buffered;

  /// Duration reported by the audio engine, which wins over the metadata
  /// duration once playback starts.
  final Duration? reportedDuration;

  final RepeatMode repeat;
  final bool shuffle;

  /// Whether reaching the end of the queue refills it with recommendations
  /// (spec section F). Off means the queue really stops, which is what the
  /// transport then reports.
  final bool autoplay;

  final bool isLoading;
  final String? error;

  /// Advances whenever the current track must be (re)loaded from its start:
  /// a new queue, a different index, or Repeat One restarting the same track.
  ///
  /// It is a *command* to the audio layer, not a description of it: the engine
  /// watch in `playback_service.dart` opens the media for the current track
  /// exactly once per increment, which is how "load this track" stays a single
  /// piece of state rather than a second controller beside this one.
  final int loadToken;

  /// Advances once per seek the user committed. [seekRequest] is the position
  /// to apply, so a repeated identical seek still reaches the engine.
  final int seekToken;
  final Duration seekRequest;

  bool get hasTrack => queue.isNotEmpty && index >= 0 && index < queue.length;

  Track? get current => hasTrack ? queue[index] : null;

  /// Tracks after the current one, in play order.
  List<Track> get upNext =>
      hasTrack ? queue.sublist(index + 1) : const <Track>[];

  Duration get duration => reportedDuration ?? current?.duration ?? Duration.zero;

  /// Seeking needs a known, positive duration (spec: disable seeking when the
  /// duration is unknown rather than pretending the action worked).
  bool get canSeek => hasTrack && duration > Duration.zero;

  PlaybackState copyWith({
    List<Track>? queue,
    int? index,
    bool? isPlaying,
    Duration? position,
    Duration? buffered,
    Duration? reportedDuration,
    RepeatMode? repeat,
    bool? shuffle,
    bool? autoplay,
    bool? isLoading,
    String? error,
    bool clearError = false,

    /// Drop [reportedDuration] instead of keeping it.
    ///
    /// A nullable field cannot be reset through this method's `??` default, so
    /// "start this track over" has to say so explicitly: without it a track
    /// change kept the previous track's engine-reported length, and the
    /// progress fill and the time labels were computed against the wrong
    /// duration until (or unless) the engine reported the new one.
    bool clearReportedDuration = false,
    int? loadToken,
    int? seekToken,
    Duration? seekRequest,
  }) {
    return PlaybackState(
      queue: queue ?? this.queue,
      index: index ?? this.index,
      isPlaying: isPlaying ?? this.isPlaying,
      position: position ?? this.position,
      buffered: buffered ?? this.buffered,
      repeat: repeat ?? this.repeat,
      shuffle: shuffle ?? this.shuffle,
      autoplay: autoplay ?? this.autoplay,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      reportedDuration:
          clearReportedDuration ? null : (reportedDuration ?? this.reportedDuration),
      loadToken: loadToken ?? this.loadToken,
      seekToken: seekToken ?? this.seekToken,
      seekRequest: seekRequest ?? this.seekRequest,
    );
  }
}
