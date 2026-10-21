import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_identity.dart';
import '../../theme/icons.dart';
import '../../theme/tokens.dart';
import '../../ui/screen_states.dart';
import 'sidecar_launcher.dart';
import 'sidecar_providers.dart';

/// Starts the sidecar for the app's lifetime and shows a real error state when
/// it cannot start.
///
/// The first screen the reader sees is the whole point of this widget. The
/// service takes a few seconds to come up on a cold start, and every page
/// probes it the moment it is built: without the gate the first thing on
/// screen was the "not reachable" error, even though the service was about to
/// answer — a dead end on the very first launch, and the worst possible first
/// impression.
///
/// So the gate waits. While the service is starting it shows a calm starting
/// state, and the app itself is only built once the service is healthy. The
/// first real screen is then the Home page, or the sign-in prompt when there
/// is no session — never an error the reader has to dismiss to get started.
///
/// It also owns shutdown: it asks the launcher to stop the sidecar it spawned
/// when the app exits, and again on disposal as a best-effort fallback.
class SidecarStartupGate extends ConsumerStatefulWidget {
  const SidecarStartupGate({super.key, required this.child, this.titleBar});

  final Widget child;

  /// The window's own title bar, when the platform has one.
  ///
  /// It is drawn here as well as in the app, so the window keeps its chrome
  /// while the service is starting: the reader can drag, minimize and close
  /// the window from the first frame, and the chrome does not jump in when
  /// the app appears.
  final Widget? titleBar;

  @override
  ConsumerState<SidecarStartupGate> createState() => _SidecarStartupGateState();
}

class _SidecarStartupGateState extends ConsumerState<SidecarStartupGate> {
  late final AppLifecycleListener _lifecycle;

  /// Captured while the element is alive: Riverpod forbids reading a provider
  /// from `dispose()`.
  late SidecarLauncher _launcher;

  @override
  void initState() {
    super.initState();
    // Desktop close/quit: give the launcher a chance to end the child before
    // the process goes away.
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await _launcher.shutdown();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _launcher = ref.read(sidecarLauncherProvider);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    // Platforms that never raise an exit request still get one attempt here.
    unawaited(_launcher.shutdown());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<SidecarStatus> status = ref.watch(sidecarStatusProvider);

    // A launcher that throws is a startup failure like any other.
    if (status.hasError) {
      return _withTitleBar(
        _SidecarFailure(message: _failureMessage(status.error)),
      );
    }

    final SidecarStatus? value = status.value;
    if (value == null) {
      // Still starting. The app is not built yet, so no page has probed a
      // service that is not there.
      return _withTitleBar(const _SidecarStarting());
    }
    if (!value.isReady) {
      return _withTitleBar(
        _SidecarFailure(
          message: value.message ?? 'The music service did not start.',
        ),
      );
    }
    return widget.child;
  }

  /// Puts the window's title bar above a full-screen startup state.
  ///
  /// The [Scaffold] is what fills the window with the app's own black and
  /// supplies the ambient text style: outside a [Material] the framework's
  /// fallback style is its error style, yellow and underlined, which would
  /// draw a yellow line under every word of the starting screen.
  Widget _withTitleBar(Widget screen) {
    return Scaffold(
      backgroundColor: Tokens.bg,
      body: Column(
        children: <Widget>[
          ?widget.titleBar,
          Expanded(child: screen),
        ],
      ),
    );
  }
}

/// The reason a failed start failed, in the launcher's own words.
String _failureMessage(Object? error) {
  if (error is SidecarUnavailableException) return error.message;
  return 'The music service did not start.';
}

/// The starting state: the product's name, a line that says what is happening,
/// and a quiet spinner. It is a screen, not an error — the app is on its way.
///
/// The colour is neutral on purpose: the accent is reserved for real state,
/// and a starting service is not one.
class _SidecarStarting extends StatelessWidget {
  const _SidecarStarting();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(appName, style: Tokens.pageTitle),
            const SizedBox(height: Tokens.s24),
            const SizedBox(
              width: Tokens.s24,
              height: Tokens.s24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Tokens.textSecondary,
              ),
            ),
            const SizedBox(height: Tokens.s16),
            Text(
              'Starting the music service…',
              style: Tokens.subtitle,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// The startup-failure screen. One sentence, the diagnostic, and one real action
/// (retry). Neutral tokens, like every other error state.
class _SidecarFailure extends ConsumerWidget {
  const _SidecarFailure({required this.message});

  final String message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SafeArea(
      child: StateMessage(
        message: 'The music service could not be started.',
        footnote: message,
        actionLabel: 'Try again',
        actionIcon: AppIcons.arrowClockwise,
        onAction: () => ref.read(sidecarStatusProvider.notifier).retry(),
      ),
    );
  }
}
