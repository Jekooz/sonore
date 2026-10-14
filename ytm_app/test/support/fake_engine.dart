import 'dart:async';

import 'package:ytm_app/audio/equalizer.dart';
import 'package:ytm_app/audio/playback_engine.dart';

/// A controllable stand-in for the audio engine.
///
/// It is a test double for the *platform* boundary only: the wiring under test
/// is the production [PlaybackService] and [PlaybackController]. It records the
/// commands it received and lets a test drive engine events (position, duration,
/// end of media, failure) deterministically, which the native engine cannot do.
///
/// It proves nothing about real audio output; that is what the integration test
/// in `integration_test/` is for.
class FakePlaybackEngine implements PlaybackEngine {
  final StreamController<Duration> _position =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> _duration =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> _buffer =
      StreamController<Duration>.broadcast();
  final StreamController<bool> _playing = StreamController<bool>.broadcast();
  final StreamController<bool> _completed = StreamController<bool>.broadcast();
  final StreamController<String> _error = StreamController<String>.broadcast();

  /// Stream URLs handed to [open], in order.
  final List<String> openedUrls = <String>[];

  /// Every command in the order it arrived, e.g. `open:play`, `pause`,
  /// `seek:1500`, `stop`.
  final List<String> commands = <String>[];

  @override
  bool isCompleted = false;

  /// When set, [open] throws it, exercising the engine-failure path.
  Object? openError;

  /// When set, the next [seek] throws it.
  Object? seekError;

  bool disposed = false;

  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  Stream<Duration> get durationStream => _duration.stream;

  @override
  Stream<Duration> get bufferStream => _buffer.stream;

  @override
  Stream<bool> get playingStream => _playing.stream;

  @override
  Stream<bool> get completedStream => _completed.stream;

  @override
  Stream<String> get errorStream => _error.stream;

  @override
  Future<void> open(String url, {required bool play}) async {
    if (openError != null) throw openError!;
    openedUrls.add(url);
    commands.add(play ? 'open:play' : 'open:pause');
    isCompleted = false;
  }

  @override
  Future<void> play() async => commands.add('play');

  @override
  Future<void> pause() async => commands.add('pause');

  @override
  Future<void> seek(Duration position) async {
    if (seekError != null) throw seekError!;
    commands.add('seek:${position.inMilliseconds}');
  }

  @override
  Future<void> stop() async {
    commands.add('stop');
    isCompleted = false;
  }

  /// The equalizer capability under test. Defaults to one that really records
  /// what it was given and reports it back, exactly as the libmpv engine does,
  /// so the Equalizer screen and its controller are exercised against the real
  /// interface rather than a stub that always succeeds silently.
  final RecordingEqualizerEngine equalizerEngine = RecordingEqualizerEngine();

  @override
  EqualizerEngine get equalizer => equalizerEngine;

  @override
  Future<void> dispose() async {
    disposed = true;
    await _position.close();
    await _duration.close();
    await _buffer.close();
    await _playing.close();
    await _completed.close();
    await _error.close();
  }

  // ---- test drivers ----

  void emitPosition(Duration value) => _position.add(value);

  void emitDuration(Duration value) => _duration.add(value);

  void emitBuffer(Duration value) => _buffer.add(value);

  void emitPlaying(bool value) => _playing.add(value);

  /// End of media, in the order the real engine does it: the completed flag is
  /// set before the streams emit, and `playing == false` precedes
  /// `completed == true`.
  void emitEndOfMedia() {
    isCompleted = true;
    _playing.add(false);
    _completed.add(true);
  }

  void emitError(String message) => _error.add(message);
}

/// A stand-in for the engine's real audio-shaping capability.
///
/// It keeps every configuration it is given and echoes the matching filter
/// string back, which is the same contract [LibmpvEqualizer] honours: apply the
/// change, then report what the pipeline now holds.
class RecordingEqualizerEngine implements EqualizerEngine {
  final List<EqualizerConfig> applied = <EqualizerConfig>[];

  EqualizerConfig? current;

  /// Set to make [apply] fail, exercising the engine-rejects path.
  Object? applyError;

  bool supported = true;

  @override
  bool get isSupported => supported;

  @override
  Future<void> apply(EqualizerConfig config) async {
    final Object? error = applyError;
    if (error != null) throw error;
    applied.add(config);
    current = config;
  }

  @override
  Future<String?> readFilter() async {
    final EqualizerConfig? config = current;
    if (config == null) return '';
    return config.enabled ? buildMpvAudioFilter(config.gains) : '';
  }
}
