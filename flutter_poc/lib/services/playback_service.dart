import 'dart:async';

import 'package:media_kit/media_kit.dart';

import 'seek_policy.dart';

/// Initialises the playback engine. Exposed here so UI code never has to import
/// the engine package directly — the UI only ever sees [PlaybackService].
void initializePlaybackEngine() => MediaKit.ensureInitialized();

/// The boundary design.md section 4 requires: the UI talks to this interface and
/// never to platform audio code. Windows and Android both run the media_kit
/// implementation, so a future platform swap only touches this file.
abstract class PlaybackService {
  Stream<Duration> get positionStream;
  Stream<Duration> get durationStream;
  Stream<bool> get playingStream;

  Duration get position;
  Duration get duration;
  bool get isPlaying;
  bool get hasTrack;

  /// False until a track is loaded and its duration is known — the UI must show
  /// a clear "cannot seek yet" state instead of pretending (design.md 3.E).
  bool get canSeek;

  Future<void> load(String url, {bool play = true});
  Future<void> play();
  Future<void> pause();
  Future<void> togglePlayPause();
  Future<void> seek(Duration target);
  Future<void> dispose();
}

/// media_kit-backed implementation (Android + Windows via the *_libs_* packages
/// declared in pubspec.yaml).
class MediaKitPlaybackService implements PlaybackService {
  MediaKitPlaybackService();

  final Player _player = Player();
  bool _hasTrack = false;

  @override
  Stream<Duration> get positionStream => _player.stream.position;

  @override
  Stream<Duration> get durationStream => _player.stream.duration;

  @override
  Stream<bool> get playingStream => _player.stream.playing;

  @override
  Duration get position => _player.state.position;

  @override
  Duration get duration => _player.state.duration;

  @override
  bool get isPlaying => _player.state.playing;

  @override
  bool get hasTrack => _hasTrack;

  @override
  bool get canSeek => _hasTrack && _player.state.duration > Duration.zero;

  @override
  Future<void> load(String url, {bool play = true}) async {
    _hasTrack = true;
    await _player.open(Media(url), play: play);
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> togglePlayPause() => _player.playOrPause();

  @override
  Future<void> seek(Duration target) async {
    final clamped = clampSeekTarget(target, _player.state.duration);
    if (clamped == null) return; // fail quietly rather than corrupt playback state
    await _player.seek(clamped);
  }

  @override
  Future<void> dispose() => _player.dispose();
}
