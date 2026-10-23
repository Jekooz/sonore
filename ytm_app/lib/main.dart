import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'audio/listening_event.dart';
import 'audio/playback_engine.dart';
import 'audio/playback_service.dart';
import 'audio/track.dart';
import 'features/shell/window_material.dart';
import 'features/shell/window_snap.dart';
import 'core/app_identity.dart';
import 'core/app_settings.dart';
import 'core/settings_persistence.dart';
import 'core/sidecar/sidecar_io.dart';
import 'core/sidecar/sidecar_providers.dart';
import 'data/ytm_repository.dart';
import 'features/shell/window_title_bar.dart';
import 'routing/app_router.dart';
import 'theme/tokens.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Registers libmpv before any player is constructed.
  initialisePlaybackEngine();

  Widget? titleBar;
  if (Platform.isWindows) {
    // The app draws its own title bar, so the native one is hidden and the
    // caption buttons below call back into window_manager.
    await windowManager.ensureInitialized();
    const WindowOptions options = WindowOptions(
      title: appName,
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: Tokens.transparent,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
    // Native window material under the in-app ambient backdrop: Mica on
    // Windows 11, nothing (the app's own backdrop fills the window) where the
    // OS cannot provide it. The plugin answers with an error on Windows 10
    // builds that lack the effect; the backdrop is the design either way.
    try {
      await acrylic.Window.initialize();
    } catch (_) {
      // No native material available: keep the plain window surface, which
      // restore paths already render correctly on.
    }
    titleBar = const WindowsTitleBar();
  }

  // Preferences are read before the first frame, so the app opens on whatever
  // the user last chose and no screen ever waits on disk while building. A
  // store that cannot be opened or read falls back to session-scoped defaults
  // rather than refusing to start.
  final SettingsStore settingsStore = await _openSettingsStore();
  final AppSettings initialSettings = await _loadSettings(settingsStore);
  // The window material follows Reduce transparency from the first frame.
  await WindowMaterial.apply(
    solid: initialSettings.reduceTransparency,
    force: true,
  );

  runApp(
    ProviderScope(
      // The composition root wires the two layers together. The audio layer has
      // no dependency on the API client: it asks for a stream URL through this
      // seam, and the resolver hands the signed URL straight to the engine
      // without storing, logging or exposing it.
      overrides: [
        streamUrlResolverProvider.overrideWith(
          (Ref ref) =>
              (Track track) => ref.read(ytmRepositoryProvider).streamUrl(track),
        ),
        // Autoplay, the next-track prefetch and listening events all read real
        // endpoints, so the audio layer reaches them through these seams rather
        // than importing the API client.
        autoplayResolverProvider.overrideWith(
          (Ref ref) =>
              (Track seed, List<String> exclude) => ref
                  .read(ytmRepositoryProvider)
                  .recommendations(seed, exclude: exclude),
        ),
        trackPrefetcherProvider.overrideWith(
          (Ref ref) =>
              (Track track) => ref.read(ytmRepositoryProvider).prefetch(track),
        ),
        listeningReporterProvider.overrideWith(
          (Ref ref) =>
              (ListeningEvent event) =>
                  ref.read(ytmRepositoryProvider).reportListeningEvent(event),
        ),
        // The local taste layer: one play, skip or like, reported as it
        // happens. Fire and forget — a failure there must never interrupt
        // playback.
        tasteReporterProvider.overrideWith(
          (Ref ref) =>
              (
                String kind,
                Track track, {
                double listenedSeconds = 0,
                double durationSeconds = 0,
                bool completed = false,
                double playedFraction = 0,
              }) => ref
                  .read(ytmRepositoryProvider)
                  .reportTasteEvent(
                    kind,
                    track,
                    listenedSeconds: listenedSeconds,
                    durationSeconds: durationSeconds,
                    completed: completed,
                    playedFraction: playedFraction,
                  ),
        ),
        // The sidecar owns its own lifecycle only on Windows, where the app
        // ships next to the repo. Elsewhere the default no-op launcher is kept,
        // so no platform-specific spawn assumption is made.
        if (Platform.isWindows)
          sidecarLauncherProvider.overrideWithValue(createSidecarLauncher()),
        // Real persistence for appearance, lyrics and equalizer preferences.
        settingsStoreProvider.overrideWithValue(settingsStore),
        initialAppSettingsProvider.overrideWithValue(initialSettings),
      ],
      child: YtmApp(
        router: createAppRouter(titleBar: titleBar),
        // The startup gate draws the same title bar while the service comes
        // up, so the window has its chrome from the first frame.
        titleBar: titleBar,
      ),
    ),
  );
}

Future<SettingsStore> _openSettingsStore() async {
  try {
    return await SharedPreferencesSettingsStore.open();
  } catch (_) {
    return InMemorySettingsStore();
  }
}

Future<AppSettings> _loadSettings(SettingsStore store) async {
  try {
    return await store.load();
  } catch (_) {
    return const AppSettings();
  }
}

/// Binds [WindowTitleBar] to the real window operations.
///
/// Kept here rather than in the widget so the title bar itself stays free of
/// platform channels and can be rendered in tests and goldens.
class WindowsTitleBar extends StatefulWidget {
  const WindowsTitleBar({super.key});

  @override
  State<WindowsTitleBar> createState() => _WindowsTitleBarState();
}

class _WindowsTitleBarState extends State<WindowsTitleBar> {
  bool _maximized = false;

  Future<void> _toggleMaximize() async {
    final bool isMaximized = await windowManager.isMaximized();
    if (isMaximized) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
    if (mounted) setState(() => _maximized = !isMaximized);
  }

  @override
  Widget build(BuildContext context) {
    return WindowTitleBar(
      title: appName,
      isMaximized: _maximized,
      onDragStart: windowManager.startDragging,
      onMinimize: windowManager.minimize,
      onMaximizeToggle: _toggleMaximize,
      onClose: windowManager.close,
      onSnapLeft: WindowSnap.snapLeft,
      onSnapRight: WindowSnap.snapRight,
    );
  }
}
