import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/icons.dart';
import '../../theme/tokens.dart';
import '../../ui/screen_states.dart';
import 'sidecar_launcher.dart';
import 'sidecar_providers.dart';

/// Starts the sidecar for the app's lifetime and shows a real error state when
/// it cannot start.
///
/// Starting and ready both render [child]: readiness must not gate the UI,
/// because the connection probe already reports offline and signed-out states
/// honestly, and blocking on startup would flash a spinner over an app that is
/// about to work. Only a genuine startup failure replaces the app.
///
/// It also owns shutdown: it asks the launcher to stop the sidecar it spawned
/// when the app exits, and again on disposal as a best-effort fallback.
class SidecarStartupGate extends ConsumerStatefulWidget {
  const SidecarStartupGate({super.key, required this.child});

  final Widget child;

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
    final SidecarStatus? status = ref.watch(sidecarStatusProvider).value;
    if (status != null && !status.isReady) {
      return _SidecarFailure(
        message: status.message ?? 'The music service did not start.',
      );
    }
    return widget.child;
  }
}

/// The startup-failure screen. One sentence, the diagnostic, and one real action
/// (retry). Neutral tokens, like every other error state.
class _SidecarFailure extends ConsumerWidget {
  const _SidecarFailure({required this.message});

  final String message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ColoredBox(
      color: Tokens.bg,
      child: SafeArea(
        child: StateMessage(
          message: 'The music service could not be started.',
          footnote: message,
          actionLabel: 'Try again',
          actionIcon: AppIcons.arrowClockwise,
          onAction: () => ref.read(sidecarStatusProvider.notifier).retry(),
        ),
      ),
    );
  }
}
