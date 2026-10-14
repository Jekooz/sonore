import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ytm_app/core/sidecar/sidecar_io.dart';
import 'package:ytm_app/core/sidecar/sidecar_launcher.dart';

/// The real sidecar lifecycle, on Windows, against the real Python service.
///
/// Isolated on purpose: a unique temporary directory holds the port file and
/// the backend log, and the child is told to publish there (YTM_PORT_FILE) on a
/// dedicated port (YTM_PORT). Nothing here reads, writes or deletes the shared
/// `%TEMP%/ytmusic_sidecar_port.txt`, so a sidecar a user already has running is
/// left alone. Run it with:
///   flutter test integration_test/sidecar_lifecycle_test.dart -d windows
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const int testPort = 8199;

  testWidgets('starts an isolated real sidecar, becomes healthy, and stops '
      'cleanly without touching the shared port file', (WidgetTester tester) async {
    final Directory dir =
        Directory.systemTemp.createTempSync('ytm_sidecar_lifecycle');
    final File portFile = File('${dir.path}${Platform.pathSeparator}port.txt');
    final File logFile = File('${dir.path}${Platform.pathSeparator}backend.log');

    // The production port file must be byte-identical before and after.
    final File sharedPortFile = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'ytmusic_sidecar_port.txt',
    );
    final String? sharedBefore =
        sharedPortFile.existsSync() ? sharedPortFile.readAsStringSync() : null;

    final SidecarLauncher launcher = createSidecarLauncher(
      environment: <String, String>{
        'YTM_PORT': '$testPort',
        'YTM_PORT_FILE': portFile.path,
      },
      portFile: portFile,
      logFile: logFile,
    );

    addTearDown(() async {
      // Always stop only what this test started, then remove our temp dir, even
      // if an assertion above failed.
      await launcher.shutdown();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    int? pid;
    try {
      final SidecarStatus status = await launcher.start();
      expect(status.isReady, isTrue, reason: status.message ?? '');
      expect(status.port, testPort);
      expect(status.reused, isFalse);

      // The spawned service answers on its own health endpoint.
      expect(await httpHealthProbe(testPort), isTrue);

      pid = (launcher as SidecarLifecycle).processId;
      expect(pid, isNotNull);

      // It published to the isolated file, which is exactly the discovery
      // contract, just at a path of our choosing.
      expect(portFile.existsSync(), isTrue);
      expect(portFile.readAsStringSync().trim(), '$testPort');
    } finally {
      await launcher.shutdown();
    }

    // The service is gone within a bounded window.
    bool stillServing = true;
    for (int i = 0; i < 50; i++) {
      stillServing = await httpHealthProbe(testPort);
      if (!stillServing) break;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(stillServing, isFalse, reason: 'sidecar still serving after shutdown');

    // The process itself is gone (killPid returns false for a dead pid).
    expect(Process.killPid(pid!, ProcessSignal.sigterm), isFalse,
        reason: 'pid $pid was still alive');

    // The shared production port file was never read, written or deleted.
    final String? sharedAfter =
        sharedPortFile.existsSync() ? sharedPortFile.readAsStringSync() : null;
    expect(sharedAfter, sharedBefore,
        reason: 'a live app\'s port file was disturbed');
  });
}
