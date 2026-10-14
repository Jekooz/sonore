import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ytm_app/core/sidecar/sidecar_launcher.dart';

/// Deterministic lifecycle tests: every external effect is a fake, so no test
/// spawns a real process, waits in real time or touches the network.

class FakeProcess implements SidecarProcess {
  FakeProcess({this.pid = 4242});

  @override
  final int pid;

  bool _exited = false;
  int? _code;
  final StreamController<String> _out = StreamController<String>.broadcast();
  final StreamController<String> _err = StreamController<String>.broadcast();

  @override
  bool get hasExited => _exited;

  @override
  int? get exitCode => _code;

  @override
  Stream<String> get stdout => _out.stream;

  @override
  Stream<String> get stderr => _err.stream;

  void exit(int code) {
    _code = code;
    _exited = true;
  }

  void emitError(String line) => _err.add(line);
}

class RecordingSpawner implements ProcessSpawner {
  final List<SidecarSpawnSpec> specs = <SidecarSpawnSpec>[];
  FakeProcess? process;
  void Function(FakeProcess process)? onSpawn;

  @override
  Future<SidecarProcess> spawn(SidecarSpawnSpec spec) async {
    specs.add(spec);
    final FakeProcess p = process ??= FakeProcess();
    onSpawn?.call(p);
    return p;
  }
}

class FakePortFile implements PortFile {
  int? value;
  int deletes = 0;

  @override
  Future<int?> read() async => value;

  @override
  Future<void> delete() async {
    deletes++;
    value = null;
  }
}

class FakeHealth {
  bool Function(int port)? responder;
  final List<int> probed = <int>[];

  Future<bool> call(int port) async {
    probed.add(port);
    return responder?.call(port) ?? true;
  }
}

class RecordingLog implements BackendLogSink {
  final List<String> lines = <String>[];

  @override
  Future<void> append(Iterable<String> lines) async => this.lines.addAll(lines);

  String get text => lines.join('\n');
}

class FakeKiller {
  final List<int> killed = <int>[];
  bool result = true;
  void Function(int pid)? onKill;

  Future<bool> call(int pid) async {
    killed.add(pid);
    onKill?.call(pid);
    return result;
  }
}

class FakeResolver implements SidecarResolver {
  FakeResolver(this.spec);

  final SidecarSpawnSpec spec;
  Object? error;

  @override
  Future<SidecarSpawnSpec> resolve() async {
    final Object? failure = error;
    if (failure != null) throw failure;
    return spec;
  }
}

SidecarSpawnSpec _spec() => const SidecarSpawnSpec(
      executable: 'python',
      arguments: <String>['/repo/backend/main.py'],
      workingDirectory: '/repo/backend',
    );

void main() {
  late FakePortFile portFile;
  late RecordingSpawner spawner;
  late FakeHealth health;
  late RecordingLog log;
  late FakeKiller killer;
  late FakeResolver resolver;
  late DateTime now;
  late SidecarLifecycle launcher;

  setUp(() {
    portFile = FakePortFile();
    spawner = RecordingSpawner();
    health = FakeHealth();
    log = RecordingLog();
    killer = FakeKiller();
    resolver = FakeResolver(_spec());
    now = DateTime(2026, 1, 1);
    // Kill marks the fake process gone, mirroring a successful taskkill.
    killer.onKill = (int pid) => spawner.process?.exit(0);

    launcher = SidecarLifecycle(
      spawner: spawner,
      portFile: portFile,
      health: health.call,
      log: log,
      killTree: killer.call,
      resolver: resolver,
      // Fast-forward the clock instead of waiting in real time.
      delay: (Duration d) async => now = now.add(d),
      clock: () => now,
      pollInterval: const Duration(milliseconds: 200),
    );
  });

  group('startup', () {
    test('spawns, waits for the port file and becomes ready on /health',
        () async {
      spawner.onSpawn = (FakeProcess p) => portFile.value = 8081;
      health.responder = (int port) => port == 8081;

      final SidecarStatus status = await launcher.start();

      expect(status.isReady, isTrue);
      expect(status.port, 8081);
      expect(status.reused, isFalse);
      expect(spawner.specs, hasLength(1));
      expect(spawner.specs.single.arguments, <String>['/repo/backend/main.py']);
      expect(log.text, contains('ready on port 8081'));
    });

    test('reuses a healthy sidecar instead of spawning a second one', () async {
      portFile.value = 8000;
      health.responder = (int port) => port == 8000;

      final SidecarStatus status = await launcher.start();

      expect(status.isReady, isTrue);
      expect(status.reused, isTrue);
      expect(status.port, 8000);
      expect(spawner.specs, isEmpty);
      // A live instance's port file must not be deleted or overwritten.
      expect(portFile.deletes, 0);
      expect(portFile.value, 8000);
    });

    test('a stale port file is cleared before a new sidecar is spawned',
        () async {
      portFile.value = 8000;
      health.responder = (int port) => port == 8081; // nothing on 8000
      spawner.onSpawn = (FakeProcess p) => portFile.value = 8081;

      final SidecarStatus status = await launcher.start();

      expect(status.isReady, isTrue);
      expect(status.reused, isFalse);
      expect(status.port, 8081);
      // Exactly one delete, before the spawn, of a file nothing was serving.
      expect(portFile.deletes, 1);
    });

    test('times out when the port file never appears', () async {
      health.responder = (_) => false; // no port file is ever published

      final SidecarStatus status = await launcher.start();

      expect(status.isReady, isFalse);
      expect(status.message, contains('did not start in time'));
      expect(spawner.specs, hasLength(1));
      // A failed start must not leak the child it spawned.
      expect(killer.killed, contains(spawner.process!.pid));
    });

    test('reports a premature exit with its exit code', () async {
      spawner.onSpawn = (FakeProcess p) => p.exit(3);

      final SidecarStatus status = await launcher.start();

      expect(status.isReady, isFalse);
      expect(status.message, contains('exited with code 3'));
    });

    test('a dead process before readiness fails fast, without both timeouts',
        () async {
      spawner.onSpawn = (FakeProcess p) => p.exit(1);
      final DateTime started = now;

      await launcher.start();

      // The loop returns as soon as it sees hasExited, not after the full
      // 20s + 15s deadlines.
      expect(now.difference(started), lessThan(const Duration(seconds: 1)));
    });
  });

  group('readiness recovery', () {
    test('a health failure is reported, and a retry succeeds once the service '
        'answers', () async {
      spawner.onSpawn = (FakeProcess p) => portFile.value = 8081;
      health.responder = (_) => false;

      final SidecarStatus first = await launcher.start();
      expect(first.isReady, isFalse);
      expect(first.message, contains('did not become ready'));

      // The service finishes starting; the same published port now answers.
      health.responder = (int port) => port == 8081;
      final SidecarStatus second = await launcher.start();

      expect(second.isReady, isTrue);
      expect(second.port, 8081);
    });
  });

  group('duplicate starts', () {
    test('concurrent starts spawn exactly once', () async {
      spawner.onSpawn = (FakeProcess p) => portFile.value = 8081;
      health.responder = (_) => true;

      final List<SidecarStatus> results = await Future.wait(<Future<SidecarStatus>>[
        launcher.start(),
        launcher.start(),
      ]);

      expect(results.every((SidecarStatus s) => s.isReady), isTrue);
      expect(spawner.specs, hasLength(1));
    });

    test('a start after ready does not spawn again', () async {
      spawner.onSpawn = (FakeProcess p) => portFile.value = 8081;
      health.responder = (_) => true;

      await launcher.start();
      await launcher.start();

      expect(spawner.specs, hasLength(1));
    });
  });

  group('shutdown', () {
    test('stops the process it spawned and verifies it is gone', () async {
      spawner.onSpawn = (FakeProcess p) => portFile.value = 8081;
      health.responder = (_) => true;
      await launcher.start();

      await launcher.shutdown();

      expect(killer.killed, contains(spawner.process!.pid));
      expect(log.text, contains('cleanup pid='));
      expect(log.text, contains('gone=true'));
    });

    test('leaves a reused sidecar alone', () async {
      portFile.value = 8000;
      health.responder = (_) => true;
      await launcher.start();

      await launcher.shutdown();

      expect(killer.killed, isEmpty);
    });
  });

  group('safe errors and logging', () {
    test('an unresolvable runtime is a clear, spawn-free failure', () async {
      resolver.error = const SidecarUnavailableException(
        'The local music service (backend/main.py) could not be found.',
      );

      final SidecarStatus status = await launcher.start();

      expect(status.isReady, isFalse);
      expect(status.message, contains('backend/main.py'));
      expect(spawner.specs, isEmpty);
      expect(log.text, contains('backend/main.py'));
    });

    test('a failure message never carries a URL or token', () async {
      resolver.error = const SidecarUnavailableException(
        'Missing entry point (see https://x.invalid/?token=SECRET)',
      );

      final SidecarStatus status = await launcher.start();

      expect(status.message, isNot(contains('SECRET')));
      expect(status.message, contains('<url>'));
      expect(log.text, isNot(contains('SECRET')));
      expect(log.text, contains('<url>'));
    });

    test('backend output is captured with its signed URLs redacted', () async {
      spawner.onSpawn = (FakeProcess p) => portFile.value = 8081;
      health.responder = (_) => true;
      await launcher.start();

      spawner.process!.emitError(
        'Failed to open https://rr1---sn-x.googlevideo.com/videoplayback?key=SECRET',
      );
      // Let the stream subscription run.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(log.text, contains('<url>'));
      expect(log.text, isNot(contains('SECRET')));
      expect(log.text, isNot(contains('googlevideo')));
      expect(log.text, isNot(contains('https://')));
    });
  });

  group('noop launcher', () {
    test('the default launcher reports ready and spawns nothing', () async {
      const SidecarLauncher noop = NoopSidecarLauncher();
      final SidecarStatus status = await noop.start();
      expect(status.isReady, isTrue);
      expect(status.port, isNull);
      await noop.shutdown();
    });
  });
}
