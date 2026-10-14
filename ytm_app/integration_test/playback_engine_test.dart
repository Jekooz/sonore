import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ytm_app/audio/playback_engine.dart';

/// Drives the real [MediaKitPlaybackEngine] — the actual native decoder (libmpv)
/// the app ships — over a controlled local audio source.
///
/// The source is a WAV this test writes itself: a deterministic 440 Hz tone of
/// known length. There is no network, no sidecar and no session involved, so a
/// failure here is a failure of the engine boundary the app depends on: load,
/// decode, report position and duration, and report completion.
///
/// Run it against the real native library with:
///   flutter test integration_test/playback_engine_test.dart -d windows

/// Writes [seconds] of a 440 Hz mono 16-bit PCM sine wave as a WAV file.
File writeTone(Directory dir, double seconds) {
  const int sampleRate = 44100;
  const double frequency = 440;
  final int sampleCount = (sampleRate * seconds).round();
  final int dataBytes = sampleCount * 2;
  final ByteData data = ByteData(44 + dataBytes);

  void ascii(int offset, String value) {
    for (int i = 0; i < value.length; i++) {
      data.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  // RIFF/WAVE header for PCM.
  ascii(0, 'RIFF');
  data.setUint32(4, 36 + dataBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little); // fmt chunk size
  data.setUint16(20, 1, Endian.little); // PCM
  data.setUint16(22, 1, Endian.little); // mono
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little); // byte rate
  data.setUint16(32, 2, Endian.little); // block align
  data.setUint16(34, 16, Endian.little); // bits per sample
  ascii(36, 'data');
  data.setUint32(40, dataBytes, Endian.little);

  for (int i = 0; i < sampleCount; i++) {
    final double t = i / sampleRate;
    final int value = (sin(2 * pi * frequency * t) * 0.3 * 32767).round();
    data.setInt16(44 + i * 2, value, Endian.little);
  }

  final File file = File('${dir.path}${Platform.pathSeparator}tone.wav');
  file.writeAsBytesSync(data.buffer.asUint8List());
  return file;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late MediaKitPlaybackEngine engine;

  setUpAll(initialisePlaybackEngine);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ytm_engine_test');
    engine = MediaKitPlaybackEngine();
  });

  tearDown(() async {
    await engine.dispose();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  testWidgets('the real engine decodes a local file and plays to the end',
      (WidgetTester tester) async {
    final File tone = writeTone(dir, 1.0);
    // The header alone is 44 bytes; a written tone is far larger.
    expect(tone.lengthSync(), greaterThan(1000));

    final Completer<Duration> reachedPosition = Completer<Duration>();
    final Completer<Duration> reportedDuration = Completer<Duration>();
    final Completer<void> completed = Completer<void>();
    final List<String> errors = <String>[];

    final StreamSubscription<Duration> positionSub = engine.positionStream.listen(
      (Duration position) {
        if (position > Duration.zero && !reachedPosition.isCompleted) {
          reachedPosition.complete(position);
        }
      },
    );
    final StreamSubscription<Duration> durationSub = engine.durationStream.listen(
      (Duration duration) {
        if (duration > Duration.zero && !reportedDuration.isCompleted) {
          reportedDuration.complete(duration);
        }
      },
    );
    final StreamSubscription<bool> completedSub = engine.completedStream.listen(
      (bool value) {
        if (value && !completed.isCompleted) completed.complete();
      },
    );
    final StreamSubscription<String> errorSub =
        engine.errorStream.listen(errors.add);
    addTearDown(positionSub.cancel);
    addTearDown(durationSub.cancel);
    addTearDown(completedSub.cancel);
    addTearDown(errorSub.cancel);

    await engine.open(tone.uri.toString(), play: true);

    // A real decoder moves the position off zero.
    final Duration position = await reachedPosition.future
        .timeout(const Duration(seconds: 20));
    expect(position, greaterThan(Duration.zero));

    // The decoded duration is the tone's real length, not a metadata guess.
    final Duration duration = await reportedDuration.future
        .timeout(const Duration(seconds: 20));
    expect(duration.inMilliseconds, closeTo(1000, 400));

    // The one-second tone reaches its end on its own.
    await completed.future.timeout(const Duration(seconds: 30));

    // Nothing about a local file should have failed.
    expect(errors, isEmpty);
  });
}
