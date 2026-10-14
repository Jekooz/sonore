import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_settings.dart';
import 'equalizer.dart';
import 'listening_event.dart';
import 'equalizer_controller.dart';
import 'playback_controller.dart';
import 'playback_engine.dart';
import 'playback_state.dart';
import 'track.dart';

/// Resolves a playable, short-lived stream URL for [track].
///
/// The data layer implements this against the sidecar's `/stream/{videoId}`.
/// It is a seam, like `artworkResolverProvider`: the audio layer never imports
/// the API client, and tests override it with a fixture.
typedef StreamUrlResolver = Future<String> Function(Track track);

/// A failure the playback layer can show the user as-is.
///
/// The data layer's resolver throws this with a message that is already safe to
/// display — no stream URL, no session value, no stack trace — so the audio
/// layer never has to know about HTTP status codes or the API client.
abstract class PlaybackFailure implements Exception {
  String get message;
}

/// Supplied by the composition root (`main.dart`). Reading it without an
/// override fails loudly rather than playing silence.
final Provider<StreamUrlResolver> streamUrlResolverProvider =
    Provider<StreamUrlResolver>(
  (ref) => throw StateError(
    'streamUrlResolverProvider must be overridden with the sidecar-backed '
    'resolver (see main.dart).',
  ),
);

/// Fetches more tracks for [seed], excluding the ids already queued.
///
/// Autoplay's seam, for the same reason the stream resolver is one: the audio
/// layer never imports the API client. [exclude] is the current queue, so a
/// refill cannot re-add what is already playing.
typedef AutoplayResolver = Future<List<Track>> Function(
  Track seed,
  List<String> exclude,
);

/// Warms the cache for a track that is about to play. Best effort by
/// definition: whatever it costs, it must never delay or break playback.
typedef TrackPrefetcher = Future<void> Function(Track track);

/// Reports one aggregated listening event (see [ListeningEvent]).
typedef ListeningReporter = Future<void> Function(ListeningEvent event);

/// The three sidecar-backed seams the audio layer needs, all supplied by
/// `main.dart`. Each throws when it is read without an override, so a missing
/// wire-up is a loud failure in development rather than silence in production.
final Provider<AutoplayResolver> autoplayResolverProvider =
    Provider<AutoplayResolver>(
  (ref) => throw StateError(
    'autoplayResolverProvider must be overridden with the sidecar-backed '
    'resolver (see main.dart).',
  ),
);

final Provider<TrackPrefetcher> trackPrefetcherProvider =
    Provider<TrackPrefetcher>(
  (ref) => throw StateError(
    'trackPrefetcherProvider must be overridden with the sidecar-backed '
    'prefetcher (see main.dart).',
  ),
);

final Provider<ListeningReporter> listeningReporterProvider =
    Provider<ListeningReporter>(
  (ref) => throw StateError(
    'listeningReporterProvider must be overridden with the sidecar-backed '
    'reporter (see main.dart).',
  ),
);

/// The playback engine. Overridden in widget tests with a fake so no native
/// audio library is loaded while pumping frames.
final Provider<PlaybackEngine> playbackEngineProvider =
    Provider<PlaybackEngine>((ref) {
  final PlaybackEngine engine = MediaKitPlaybackEngine();
  ref.onDispose(engine.dispose);
  return engine;
});

/// Connects the single [PlaybackController] to a real audio engine.
///
/// The controller stays the one authority for *what* should be playing; this
/// watches its state and drives the engine to match. That direction (state →
/// engine) is deliberate:
///
/// * every existing action — `next()`, `togglePlayPause()`, `seek()`, selecting
///   a row anywhere in the app — already flows through the controller, so none
///   of them needs to know an engine exists;
/// * `loadToken` and `seekToken` make "load this" and "seek here" exactly-once
///   commands, so a rebuild or a repeated identical seek cannot double-fire;
/// * the engine reports back through `reportProgress` / `completeTrack` /
///   `reportPaused`, which is what keeps the UI truthful about real playback.
///
/// Failures do not throw at the widget layer: an unresolvable stream or an
/// engine error becomes a message in [PlaybackState.error] with a working Retry.
class PlaybackService {
  PlaybackService(this._ref) {
    final PlaybackState initial = _ref.read(playbackProvider);
    // Adopt whatever state the container already holds without commanding the
    // engine: a pre-seeded queue (tests, goldens) is not a play instruction.
    _loadedLoadToken = initial.loadToken;
    _appliedSeekToken = initial.seekToken;
    _commandedPlaying = initial.isPlaying;
    _listenToEngine();
    _applyPersistedEqualizer();
    _ref.listen<PlaybackState>(
      playbackProvider,
      (PlaybackState? previous, PlaybackState next) => _reconcile(next),
    );
  }

  final Ref _ref;

  PlaybackEngine get _engine => _ref.read(playbackEngineProvider);
  PlaybackController get _controller => _ref.read(playbackProvider.notifier);
  PlaybackState get _state => _ref.read(playbackProvider);

  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];

  /// Load commands already executed (one per `loadToken`).
  int _loadedLoadToken = 0;

  /// Seeks already applied (one per `seekToken`).
  int _appliedSeekToken = 0;

  /// The play/pause value the engine was last told, so a command is sent once.
  bool _commandedPlaying = false;

  /// Invalidates an in-flight load when the user moves on before it finishes:
  /// a slow stream resolve must not start playing a track they have left.
  int _loadEpoch = 0;

  /// Whether audio has actually started for the current media. Guards against
  /// treating a pre-start `playing == false` as a user pause.
  bool _sawPlaying = false;

  /// The track the engine is actually on, plus how far it has been heard and
  /// when it started, so the track can be reported once with real numbers when
  /// it is left.
  Track? _playing;
  Duration _heard = Duration.zero;
  DateTime? _startedAt;

  /// The next track already warmed, so one track is prefetched once.
  String? _prefetchedId;

  /// One Autoplay refill at a time: the resolver is a network call and the
  /// engine can report completion again while it is in flight.
  bool _extending = false;

  bool _disposed = false;

  void _listenToEngine() {
    final PlaybackEngine engine = _engine;
    _subscriptions.addAll(<StreamSubscription<Object?>>[
      engine.positionStream.listen(_onPosition),
      engine.durationStream.listen(
        (Duration duration) => _controller.reportProgress(duration: duration),
      ),
      engine.bufferStream.listen(
        (Duration buffered) => _controller.reportProgress(buffered: buffered),
      ),
      engine.playingStream.listen(_onPlayingChanged),
      engine.completedStream.listen(_onCompletedChanged),
      engine.errorStream.listen(_onEngineError),
    ]);
  }

  /// Writes the persisted equalizer into the engine once, at startup, so audio
  /// is shaped from the first track rather than only after the Equalizer screen
  /// has been opened.
  ///
  /// The controller owns the configuration and reports failures itself; this
  /// only asks it to put the stored shape where the audio actually is. An
  /// engine without shaping support is not an error — the Equalizer screen is
  /// the thing that tells the user that.
  void _applyPersistedEqualizer() {
    final EqualizerConfig config = _ref.read(appSettingsProvider).equalizer;
    // Nothing stored means nothing to write, and the engine is already flat.
    if (!config.enabled && config.isFlat) return;
    _ref
        .read(equalizerControllerProvider.notifier)
        .applyToEngine()
        .ignore();
  }

  /// Progress from the engine. Records how much was actually heard (for the
  /// listening event) and warms the next track once this one is half played.
  void _onPosition(Duration position) {
    if (_disposed) return;
    if (position > _heard) _heard = position;
    _controller.reportProgress(position: position);
    _prefetchNextWhenHalfHeard(position);
  }

  /// Prefetches the upcoming track at the halfway mark, so pressing Next starts
  /// from cache instead of resolving the stream from scratch.
  void _prefetchNextWhenHalfHeard(Duration position) {
    final PlaybackState state = _state;
    final Duration duration = state.duration;
    if (!state.hasTrack || duration <= Duration.zero) return;
    if (position * 2 < duration) return;
    if (state.index + 1 >= state.queue.length) return;

    final Track next = state.queue[state.index + 1];
    if (next.id == _prefetchedId) return;
    _prefetchedId = next.id;
    _ref.read(trackPrefetcherProvider)(next).ignore();
  }

  /// Reports the track being left, exactly once, then forgets it.
  ///
  /// A track that never produced audio is not reported: "skipped" has to mean
  /// the listener heard something and moved on, which is the signal the ranker
  /// actually uses.
  void _reportDeparture(ListeningOutcome outcome) {
    final Track? track = _playing;
    if (track == null) return;
    _playing = null;

    final bool heardAnything = _sawPlaying || _heard > Duration.zero;
    if (outcome != ListeningOutcome.completed && !heardAnything) return;

    // A track whose length the service did not report is sent as 0 seconds of
    // duration rather than guessed from the position reached.
    final Duration? known = track.duration;
    final Duration heard = known != null && _heard > known ? known : _heard;
    final ListeningEvent event = ListeningEvent(
      videoId: track.id,
      outcome: outcome,
      title: track.title,
      artist: track.artist,
      startedAt: _startedAt == null
          ? null
          : _startedAt!.millisecondsSinceEpoch / 1000,
      listenedSeconds: heard.inMilliseconds / 1000,
      durationSeconds: (known ?? Duration.zero).inMilliseconds / 1000,
    );
    _heard = Duration.zero;
    _startedAt = null;
    _ref.read(listeningReporterProvider)(event).ignore();
  }

  Future<void> _reconcile(PlaybackState state) async {
    if (_disposed) return;

    // Nothing to play: unload the engine so a cleared queue goes silent.
    if (!state.hasTrack) {
      // A cleared queue is the listener stopping playback on purpose.
      _reportDeparture(ListeningOutcome.stopped);
      _prefetchedId = null;
      if (state.loadToken != _loadedLoadToken) {
        _loadedLoadToken = state.loadToken;
        _appliedSeekToken = state.seekToken;
        _commandedPlaying = false;
        _sawPlaying = false;
        _loadEpoch++;
        await _guard(() => _engine.stop());
      }
      return;
    }

    // A load was commanded: resolve the stream, then hand it to the engine.
    if (state.loadToken != _loadedLoadToken) {
      await _load(state);
      return;
    }

    // A seek the user committed.
    if (state.seekToken != _appliedSeekToken) {
      _appliedSeekToken = state.seekToken;
      await _guard(() => _engine.seek(state.seekRequest));
      return;
    }

    // Play / pause, sent only when it actually changes.
    if (state.isPlaying != _commandedPlaying) {
      final bool play = state.isPlaying;
      _commandedPlaying = play;
      await _guard(() => play ? _engine.play() : _engine.pause());
    }
  }

  Future<void> _load(PlaybackState state) async {
    _loadedLoadToken = state.loadToken;
    // A fresh load starts at zero by definition, so any seek queued before it
    // is already satisfied and must not be replayed on top of the new media.
    _appliedSeekToken = state.seekToken;
    _commandedPlaying = state.isPlaying;
    _sawPlaying = false;

    final int epoch = ++_loadEpoch;
    final Track track = state.current!;

    // Loading a different track means the previous one was left early (the
    // engine's own completion is reported from _onCompletedChanged instead).
    if (_playing != null && _playing!.id != track.id) {
      _reportDeparture(ListeningOutcome.skipped);
    }
    _playing = track;
    _heard = Duration.zero;
    _startedAt = DateTime.now();
    _prefetchedId = null;
    _controller.reportLoading(true);

    final String url;
    try {
      url = await _ref.read(streamUrlResolverProvider)(track);
    } catch (error) {
      if (epoch != _loadEpoch || _disposed) return; // superseded by a newer load
      _controller.reportLoading(false);
      _controller.reportError(_describe(error, track));
      return;
    }

    if (epoch != _loadEpoch || _disposed) return;
    _controller.reportLoading(false);

    try {
      await _engine.open(url, play: _state.isPlaying);
    } catch (error) {
      if (epoch != _loadEpoch || _disposed) return;
      _controller.reportError(_describe(error, track));
    }
  }

  void _onPlayingChanged(bool playing) {
    if (_disposed) return;
    if (playing) {
      _sawPlaying = true;
      return;
    }
    // Never started, or the media simply ended: neither is a user pause.
    if (!_sawPlaying || _engine.isCompleted) return;
    // The engine stopped without the app asking (an OS media key, a device
    // change). Mirror it so the play/pause control stays truthful.
    _sawPlaying = false;
    _commandedPlaying = false;
    _controller.reportPaused();
  }

  void _onCompletedChanged(bool completed) {
    if (_disposed || !completed) return;
    _reportDeparture(ListeningOutcome.completed);
    _sawPlaying = false;

    final PlaybackState state = _state;
    // Autoplay applies exactly where the queue would otherwise stop: at the end
    // of the queue, with repeat off. Repeat All is the listener asking to wrap,
    // and Repeat One is asking for the same song again, so neither is
    // overridden by a refill.
    final bool atQueueEnd =
        state.hasTrack && state.index >= state.queue.length - 1;
    if (state.autoplay &&
        state.repeat == RepeatMode.off &&
        atQueueEnd &&
        !_extending) {
      _autoplay(state);
      return;
    }

    // Otherwise end of track follows the same rules as pressing Next: Repeat
    // One reloads it, Repeat All wraps, and a repeat-off queue stops here.
    _controller.completeTrack();
  }

  /// Refills the queue with real recommendations and keeps playing.
  ///
  /// Two honest endings: if the service has nothing to add, playback stops
  /// where it would have stopped anyway, and if the request fails the failure
  /// is shown with its own message (and Retry) rather than looking like the
  /// queue simply ended.
  Future<void> _autoplay(PlaybackState state) async {
    final Track seed = state.current!;
    final List<String> exclude =
        state.queue.map((Track track) => track.id).toList(growable: false);
    _extending = true;
    try {
      final List<Track> more =
          await _ref.read(autoplayResolverProvider)(seed, exclude);
      if (_disposed) return;
      if (more.isEmpty) {
        _controller.completeTrack();
        return;
      }
      _controller.addToQueue(more);
      _controller.completeTrack();
    } catch (error) {
      if (_disposed) return;
      _controller.reportError(_describe(error, seed));
      _controller.completeTrack();
    } finally {
      _extending = false;
    }
  }

  void _onEngineError(String message) {
    if (_disposed) return;
    // The engine has already redacted signed stream URLs from this message.
    _controller.reportError(
      message.isEmpty ? 'Playback failed.' : 'Playback failed: $message',
    );
  }

  /// Runs an engine command, converting a thrown error into state rather than
  /// letting it escape the listener.
  Future<void> _guard(Future<void> Function() command) async {
    try {
      await command();
    } catch (error) {
      if (_disposed) return;
      _controller.reportError(_describe(error, _state.current));
    }
  }

  /// A short, user-facing failure with no stream URL, cookie or signed query in
  /// it (design.md section 3.I).
  static String _describe(Object error, Track? track) {
    if (error is PlaybackFailure) return error.message;
    if (error is StateError) return error.message;
    return 'Could not play "${track?.title ?? 'this track'}".';
  }

  Future<void> dispose() async {
    // Nothing is reported here on purpose. Disposal is a provider teardown, so
    // reading the reporter would be a use-after-dispose; and the three events
    // that matter (completed, skipped, stopped) are all reported while the app
    // is still running — a track that ends, a track the listener leaves, and a
    // queue the listener clears. Closing the window mid-track is not an event
    // the app can honestly deliver.
    _disposed = true;
    for (final StreamSubscription<Object?> subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
  }
}

/// The running playback service. Watch it once in the shell so the engine watch
/// is alive for the app's lifetime.
final Provider<PlaybackService> playbackServiceProvider =
    Provider<PlaybackService>((ref) {
  final PlaybackService service = PlaybackService(ref);
  ref.onDispose(service.dispose);
  return service;
});
