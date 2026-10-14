import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'sidecar_launcher.dart';

/// The sidecar launcher.
///
/// Defaults to a no-op that reports ready, so no widget test or golden ever
/// spawns a process. The composition root (`main.dart`) overrides this with the
/// real lifecycle on Windows; the recorded-sidecar seam in the data layer is
/// untouched either way.
final Provider<SidecarLauncher> sidecarLauncherProvider =
    Provider<SidecarLauncher>((ref) => const NoopSidecarLauncher());

/// The sidecar's lifecycle state.
///
/// Building it starts the sidecar once (the launcher itself deduplicates and
/// reuses a healthy service). [SidecarStatusController.retry] is the one real
/// action behind the startup-failure screen.
class SidecarStatusController extends AsyncNotifier<SidecarStatus> {
  @override
  Future<SidecarStatus> build() {
    return ref.watch(sidecarLauncherProvider).start();
  }

  Future<void> retry() async {
    state = const AsyncValue<SidecarStatus>.loading();
    state = await AsyncValue.guard(
      () => ref.read(sidecarLauncherProvider).start(),
    );
  }
}

final AsyncNotifierProvider<SidecarStatusController, SidecarStatus>
    sidecarStatusProvider =
    AsyncNotifierProvider<SidecarStatusController, SidecarStatus>(
  SidecarStatusController.new,
);
