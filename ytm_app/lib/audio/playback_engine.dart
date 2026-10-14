import 'dart:async';

import 'package:media_kit/media_kit.dart';

import 'equalizer.dart';

/// Prepares the playback backend.
///
/// Called once from `main()` before any engine exists: media_kit has to register
/// its native library location (libmpv) before a player is constructed.
void initialisePlaybackEngine() => MediaKit.ensureInitialized();

/// The boundary design.md section 4 requires: "The UI should talk to a
/// `PlaybackService` interface, never directly to platform audio code."
///
/// Only [PlaybackEngine]'s implementation and the wiring in
/// `playback_service.dart` may import the engine package; no widget does.
abstract class PlaybackEngine {
  /// Playback position as the engine reports it. The UI reconciles against this
  /// after an optimistic seek.
  Stream<Duration> get positionStream;

  /// Duration decoded from the media. Wins over the metadata duration.
  Stream<Duration> get durationStream;

  /// How far ahead of the position the stream is buffered.
  Stream<Duration> get bufferStream;

  /// True while the engine is actually producing audio.
  Stream<bool> get playingStream;

  /// Whether the current media has reached its end.
  ///
  /// media_kit puts the engine into its completed state *before* it emits, and
  /// end-of-media emits `playing == false` first and `completed == true`
  /// second. Reading this flag while handling `playing == false` is therefore
  /// what distinguishes "the track ended" from "the user paused", which would
  /// otherwise pause the UI at the end of every track.
  bool get isCompleted;

  /// Fires when the current media reaches its end.
  Stream<bool> get completedStream;

  /// Engine, decode and network failures. Every message passes through
  /// [redactStreamUrls] first, so a signed stream URL is never surfaced.
  Stream<String> get errorStream;

  /// Loads [url] and, when [play] is true, starts it immediately.
  Future<void> open(String url, {required bool play});

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);

  /// Unloads the current media. The engine stays usable afterwards.
  Future<void> stop();

  /// This engine's real audio-shaping capability, or null when it cannot shape
  /// audio. The Equalizer screen renders its unavailable state on null rather
  /// than offering controls that do nothing.
  EqualizerEngine? get equalizer;

  Future<void> dispose();
}

/// Removes signed, expiring stream URLs from an engine message.
///
/// libmpv quotes the resource it failed on ("Failed to open
/// https://…googlevideo.com/videoplayback?…"), and those URLs carry the user's
/// session. Design.md requires credentials and sensitive URLs never to be
/// logged or displayed, so every engine error is redacted before it reaches the
/// UI or a log.
String redactStreamUrls(String message) {
  return message
      .replaceAll(RegExp(r'https?://\S+'), '<stream>')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// The media_kit-backed engine: one implementation covers Android and Windows,
/// because the `media_kit_libs_*` packages ship the matching libmpv build.
class MediaKitPlaybackEngine implements PlaybackEngine {
  MediaKitPlaybackEngine() {
    _player = Player(
      configuration: const PlayerConfiguration(
        // Sets the process name shown in the Windows volume mixer.
        title: 'YT Music Client',
      ),
    );
  }

  late final Player _player;

  @override
  Stream<Duration> get positionStream => _player.stream.position;

  @override
  Stream<Duration> get durationStream => _player.stream.duration;

  @override
  Stream<Duration> get bufferStream => _player.stream.buffer;

  @override
  Stream<bool> get playingStream => _player.stream.playing;

  @override
  bool get isCompleted => _player.state.completed;

  @override
  Stream<bool> get completedStream => _player.stream.completed;

  @override
  Stream<String> get errorStream =>
      _player.stream.error.map(redactStreamUrls);

  @override
  Future<void> open(String url, {required bool play}) =>
      _player.open(Media(url), play: play);

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> stop() => _player.stop();

  /// Ten-band EQ through the same libmpv this player is already running.
  ///
  /// Built lazily so constructing an engine never loads FFI, and keyed on
  /// [MediaKitPlaybackEngine]'s own handle, so the filter lands on the instance
  /// that is actually playing.
  EqualizerEngine? _equalizer;

  @override
  EqualizerEngine get equalizer => _equalizer ??= LibmpvEqualizer(
        () async => _player.handle,
      );

  @override
  Future<void> dispose() => _player.dispose();
}
