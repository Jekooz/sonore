import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// Riverpod 3 moved `Override` out of `package:riverpod/riverpod.dart` and
// exposes it only through `misc.dart`.
import 'package:riverpod/misc.dart' show Override;
import 'package:ytm_app/app.dart';
import 'package:ytm_app/audio/listening_event.dart';
import 'package:ytm_app/audio/playback_controller.dart';
import 'package:ytm_app/audio/playback_engine.dart';
import 'package:ytm_app/audio/playback_service.dart';
import 'package:ytm_app/audio/playback_state.dart';
import 'package:ytm_app/audio/track.dart';
import 'package:ytm_app/core/sidecar/sidecar_launcher.dart';
import 'package:ytm_app/core/sidecar/sidecar_providers.dart';
import 'package:ytm_app/data/ytm_repository.dart';
import 'package:ytm_app/features/now_playing/artwork.dart';
import 'package:ytm_app/routing/app_router.dart';

import 'fake_engine.dart';
import 'recorded_sidecar.dart';

/// The font families the app declares in pubspec.yaml. Widget tests do not load
/// them automatically, so goldens would otherwise render text and icon glyphs in
/// the fallback test font.
const Map<String, List<String>> _appFonts = <String, List<String>>{
  'Inter': <String>[
    'assets/fonts/Inter-Regular.ttf',
    'assets/fonts/Inter-Medium.ttf',
    'assets/fonts/Inter-SemiBold.ttf',
    'assets/fonts/Inter-Bold.ttf',
  ],
  'PhosphorRegular': <String>['assets/fonts/Phosphor-Regular.ttf'],
  'PhosphorFill': <String>['assets/fonts/Phosphor-Fill.ttf'],
};

/// Registers the bundled Inter and Phosphor faces so goldens render real type
/// and real icon glyphs instead of the fallback test font.
Future<void> loadAppFonts() async {
  for (final MapEntry<String, List<String>> entry in _appFonts.entries) {
    final FontLoader loader = FontLoader(entry.key);
    for (final String path in entry.value) {
      final Uint8List bytes = await File(path).readAsBytes();
      loader.addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
  }
}

/// The three required viewports plus the 1.3x text-scale variant.
const Size kPhone = Size(390, 844);
const Size kTablet = Size(800, 1280);
const Size kDesktop = Size(1280, 800);
const double kAccessibleTextScale = 1.3;

/// Deterministic stand-in for the artwork palette so goldens never decode a
/// network image. Fixture colors for the tests, not design tokens.
const List<Color> kTestAmbientColors = <Color>[
  Color(0xFF7C6BC4),
  Color(0xFF3E8E7E),
  Color(0xFFE8935A),
];

/// A queue fixture. Test data only: the shipped app starts with an empty player
/// and no audio engine, so this is never rendered as if it were real content.
List<Track> testQueue() => const <Track>[
  Track(
    id: 'a',
    title: 'Falling For You',
    artist: 'Nova',
    album: 'Nightfall',
    duration: Duration(minutes: 3, seconds: 58),
    artworkUrl: 'https://example.invalid/a.png',
  ),
  Track(
    id: 'b',
    title: 'Midnight Drive',
    artist: 'Aurora Lane',
    album: 'Static',
    duration: Duration(minutes: 4, seconds: 12),
    artworkUrl: 'https://example.invalid/b.png',
  ),
  Track(
    id: 'c',
    title: 'Paper Boats',
    artist: 'Kite Club',
    duration: Duration(minutes: 2, seconds: 48),
    artworkUrl: 'https://example.invalid/c.png',
  ),
];

/// The real [PlaybackController] seeded with a queue, so tests and goldens drive
/// the production state machine rather than a parallel fixture store.
class SeededPlaybackController extends PlaybackController {
  SeededPlaybackController({
    required this.tracks,
    this.index = 0,
    this.isPlaying = true,
    this.position = const Duration(seconds: 84),
    this.error,
    this.isLoading = false,
  });

  final List<Track> tracks;
  final int index;
  final bool isPlaying;
  final Duration position;
  final String? error;
  final bool isLoading;

  @override
  PlaybackState build() => PlaybackState(
    queue: tracks,
    index: tracks.isEmpty ? 0 : index,
    isPlaying: tracks.isNotEmpty && isPlaying,
    position: position,
    buffered: const Duration(minutes: 2),
    reportedDuration: tracks.isEmpty ? null : tracks[index].duration,
    error: error,
    isLoading: isLoading,
  );
}

/// The routed app with deterministic seams: no artwork is fetched, the ambient
/// palette is fixed and the audio engine is a fake, so no golden or widget test
/// depends on the network or loads a native audio library.
Widget appScope({
  String initialLocation = '/home',
  Widget? titleBar,
  List<Track>? queue,
  int queueIndex = 0,
  bool queuePlaying = true,
  Duration queuePosition = const Duration(seconds: 84),
  String? queueError,
  bool queueLoading = false,
  PlaybackEngine? engine,
  YtmRepository? repository,
  SidecarLauncher? sidecarLauncher,
  AutoplayResolver? autoplayResolver,
  TrackPrefetcher? prefetcher,
  ListeningReporter? listeningReporter,
  List<Override> extraOverrides = const <Override>[],
}) {
  final bool seedPlayback = queue != null || queueError != null || queueLoading;

  return ProviderScope(
    overrides: [
      artworkResolverProvider.overrideWithValue((String? url) => null),
      ambientPaletteLoaderProvider.overrideWithValue(
        (String url) async => kTestAmbientColors,
      ),
      // The shell watches the playback service, so every pumped app would
      // otherwise construct a real media_kit player and load libmpv.
      playbackEngineProvider.overrideWithValue(engine ?? FakePlaybackEngine()),
      // Screens read the real repository over the recorded, anonymized sidecar
      // payloads: no test or golden ever opens a socket or needs a session.
      ytmRepositoryProvider.overrideWithValue(repository ?? testRepository()),
      // The audio layer's stream seam. Without this, any track change reaches
      // the unimplemented default and the app correctly reports an error, which
      // is not what a widget test is trying to observe. The URL is never
      // fetched: the engine under test is the fake above.
      streamUrlResolverProvider.overrideWithValue(
        (Track track) async => 'https://stream.invalid/${track.id}',
      ),
      // Autoplay, prefetch and listening events are the other three sidecar
      // seams. Tests that care about them inject recorders; everything else
      // gets the quiet defaults, so no widget test opens a socket.
      autoplayResolverProvider.overrideWithValue(
        autoplayResolver ??
            (Track seed, List<String> exclude) async => const <Track>[],
      ),
      trackPrefetcherProvider.overrideWithValue(
        prefetcher ?? (Track track) async {},
      ),
      listeningReporterProvider.overrideWithValue(
        listeningReporter ?? (ListeningEvent event) async {},
      ),
      // The sidecar launcher. The default is already a no-op, but a test can
      // inject a scripted one to exercise the startup gate deterministically.
      sidecarLauncherProvider.overrideWithValue(
        sidecarLauncher ?? const NoopSidecarLauncher(),
      ),
      ...extraOverrides,
      if (seedPlayback)
        playbackProvider.overrideWith(
          () => SeededPlaybackController(
            tracks: queue ?? const <Track>[],
            index: queueIndex,
            isPlaying: queuePlaying,
            position: queuePosition,
            error: queueError,
            isLoading: queueLoading,
          ),
        ),
    ],
    child: YtmApp(
      router: createAppRouter(
        initialLocation: initialLocation,
        titleBar: titleBar,
      ),
    ),
  );
}

/// Pumps [app] at a logical [size] with an optional text scale.
///
/// Uses the platform text-scale value so the app's own clamping is exercised,
/// and settles so asynchronous palette loads finish before a golden is captured.
Future<void> pumpAtSize(
  WidgetTester tester,
  Widget app, {
  required Size size,
  double textScale = 1,
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(() {
    tester.view.reset();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });

  await tester.pumpWidget(app);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}
