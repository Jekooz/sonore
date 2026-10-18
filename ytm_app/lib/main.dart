import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'audio/listening_event.dart';
import 'audio/playback_engine.dart';
import 'audio/playback_service.dart';
import 'audio/track.dart';
import 'core/app_identity.dart';
import 'core/app_settings.dart';
import 'core/browser_opener.dart';
import 'core/folder_reveal.dart';
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
    titleBar = const WindowsTitleBar();
  }

  // Preferences are read before the first frame, so the app opens on whatever
  // the user last chose and no screen ever waits on disk while building. A
  // store that cannot be opened or read falls back to session-scoped defaults
  // rather than refusing to start.
  final SettingsStore settingsStore = await _openSettingsStore();
  final AppSettings initialSettings = await _loadSettings(settingsStore);

  runApp(
    ProviderScope(
      // The composition root wires the two layers together. The audio layer has
      // no dependency on the API client: it asks for a stream URL through this
      // seam, and the resolver hands the signed URL straight to the engine
      // without storing, logging or exposing it.
      overrides: [
        streamUrlResolverProvider.overrideWith(
          (Ref ref) => (Track track) =>
              ref.read(ytmRepositoryProvider).streamUrl(track),
        ),
        // Autoplay, the next-track prefetch and listening events all read real
        // endpoints, so the audio layer reaches them through these seams rather
        // than importing the API client.
        autoplayResolverProvider.overrideWith(
          (Ref ref) => (Track seed, List<String> exclude) => ref
              .read(ytmRepositoryProvider)
              .recommendations(seed, exclude: exclude),
        ),
        trackPrefetcherProvider.overrideWith(
          (Ref ref) =>
              (Track track) => ref.read(ytmRepositoryProvider).prefetch(track),
        ),
        listeningReporterProvider.overrideWith(
          (Ref ref) => (ListeningEvent event) =>
              ref.read(ytmRepositoryProvider).reportListeningEvent(event),
        ),
        // The sidecar owns its own lifecycle only on Windows, where the app
        // ships next to the repo. Elsewhere the default no-op launcher is kept,
        // so no platform-specific spawn assumption is made.
        if (Platform.isWindows)
          sidecarLauncherProvider.overrideWithValue(createSidecarLauncher()),
        // Opening the helper-extension folder: the one manual step the sign-in
        // hand-off needs. The default is a no-op so no test opens a window.
        folderRevealerProvider.overrideWithValue(revealFolder),
        // Sign-in opens music.youtube.com in the user's default browser; the
        // default is a no-op so no test ever launches one.
        browserOpenerProvider.overrideWithValue(launchInBrowser),
        // Real persistence for appearance, lyrics and equalizer preferences.
        settingsStoreProvider.overrideWithValue(settingsStore),
        initialAppSettingsProvider.overrideWithValue(initialSettings),
      ],
      child: YtmApp(router: createAppRouter(titleBar: titleBar)),
    ),
  );
}

/// Opens [path] in the file manager.
///
/// `explorer` is the Windows shell's own way in and needs no plugin; elsewhere
/// there is no such program, which is why a failure stays silent. The button is
/// a convenience for a manual step rather than part of sign-in itself, so it
/// must never become an error the user has to dismiss.
Future<void> revealFolder(String path) async {
  if (!Platform.isWindows) return;
  try {
    await Process.run('explorer', <String>[path]);
  } catch (_) {
    // Ignored on purpose: see above.
  }
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
    );
  }
}
