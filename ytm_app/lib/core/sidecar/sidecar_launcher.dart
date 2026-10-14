import 'dart:async';

/// Where the sidecar is in its lifecycle, as far as the app can tell.
enum SidecarPhase {
  /// The service answered `/health` (or a healthy one was reused).
  ready,

  /// The service could not be started or did not become healthy.
  failed,
}

/// The result of a start attempt.
///
/// On failure [message] is a short line that is already safe to show the user:
/// it never contains a URL, a cookie, a token or an environment value.
class SidecarStatus {
  const SidecarStatus.ready({this.port, this.reused = false})
      : phase = SidecarPhase.ready,
        message = null;

  const SidecarStatus.failed(this.message)
      : phase = SidecarPhase.failed,
        port = null,
        reused = false;

  final SidecarPhase phase;

  /// The port the service is listening on, when it is ready.
  final int? port;

  /// True when this launch attached to a sidecar that was already running
  /// instead of spawning one.
  final bool reused;

  /// A user-safe failure sentence, or null when ready.
  final String? message;

  bool get isReady => phase == SidecarPhase.ready;
}

/// How to spawn the sidecar.
///
/// [arguments] is a list rather than a command line so no shell quoting or
/// interpolation is involved: the process is started with an argument vector.
class SidecarSpawnSpec {
  const SidecarSpawnSpec({
    required this.executable,
    required this.arguments,
    required this.workingDirectory,
    this.environment,
  });

  final String executable;
  final List<String> arguments;
  final String workingDirectory;

  /// Extra environment for the child. Null means "inherit the parent's".
  final Map<String, String>? environment;

  /// The child, with argument values elided so a log line never carries a path
  /// the user did not ask to see verbatim.
  @override
  String toString() =>
      'SidecarSpawnSpec($executable ${arguments.length} args, cwd=$workingDirectory)';
}

/// A spawned child process, abstracted so tests never start a real one.
abstract interface class SidecarProcess {
  int get pid;

  /// Whether the child has finished. Kept synchronous so the readiness loop can
  /// tell "still starting" from "died early" without awaiting.
  bool get hasExited;

  int? get exitCode;

  Stream<String> get stdout;
  Stream<String> get stderr;
}

/// Starts a child process. The real implementation wraps `dart:io`.
abstract interface class ProcessSpawner {
  Future<SidecarProcess> spawn(SidecarSpawnSpec spec);
}

/// Reads and removes the sidecar's published port file
/// (`%TEMP%/ytmusic_sidecar_port.txt`), the project's existing discovery
/// protocol.
abstract interface class PortFile {
  /// The published port, or null when the file is absent or unreadable.
  Future<int?> read();

  /// Removes a stale port file so a previous run's value cannot be mistaken for
  /// this one's.
  Future<void> delete();
}

/// Probes the sidecar's existing `GET /health` endpoint.
typedef HealthProbe = Future<bool> Function(int port);

/// Appends captured backend output to the app's bounded backend log.
abstract interface class BackendLogSink {
  Future<void> append(Iterable<String> lines);
}

/// Ends a process and its descendants. Returns true when the kill command
/// reported success. Deliberately best-effort: Windows offers no portable
/// guarantee here without a Job Object.
typedef ProcessTreeKiller = Future<bool> Function(int pid);

/// Waits between readiness polls. Injected so tests never wait in real time.
typedef Delay = Future<void> Function(Duration duration);

/// A monotonic-enough source of "now". Injected so tests can fast-forward.
typedef Clock = DateTime Function();

/// The sidecar runtime (Python, or the sidecar entry point) could not be
/// resolved. Carries a user-safe sentence.
class SidecarUnavailableException implements Exception {
  const SidecarUnavailableException(this.message);

  final String message;

  @override
  String toString() => 'SidecarUnavailableException($message)';
}

/// Resolves the process to start, or explains why it cannot be resolved.
abstract interface class SidecarResolver {
  Future<SidecarSpawnSpec> resolve();
}

/// Manages one sidecar's lifecycle. Injectable so the app and its tests can
/// substitute a fake without spawning anything.
abstract interface class SidecarLauncher {
  /// Ensures the sidecar is running and healthy, returning the outcome.
  ///
  /// Never throws: an unresolvable runtime, a spawn failure, a premature exit
  /// or a timeout all come back as [SidecarStatus.failed] with a safe message.
  Future<SidecarStatus> start();

  /// Stops a sidecar this launcher spawned. A reused sidecar is left alone
  /// because it belongs to another running process.
  Future<void> shutdown();
}

/// Removes signed, expiring stream URLs and collapses whitespace, so nothing
/// that reaches a log line, an error message or the UI carries a session value.
String redactSecrets(String value) {
  return value
      .replaceAll(RegExp(r'https?://\S+'), '<url>')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// The real lifecycle: reuse a healthy sidecar, otherwise spawn one, wait for
/// the port file and `/health` within bounded deadlines, and kill the tree on
/// shutdown.
///
/// Every external effect (spawning, the port file, health, the log, killing a
/// tree, time) is injected, so the whole thing is exercised deterministically
/// by tests with no real processes. Those dependencies are public fields so a
/// test can substitute any one of them.
class SidecarLifecycle implements SidecarLauncher {
  SidecarLifecycle({
    required this.spawner,
    required this.portFile,
    required this.health,
    required this.log,
    required this.killTree,
    required this.resolver,
    this.delay = _realDelay,
    this.clock = _realNow,
    this.portFileTimeout = const Duration(seconds: 20),
    this.healthTimeout = const Duration(seconds: 15),
    this.pollInterval = const Duration(milliseconds: 200),
    this.cleanupTimeout = const Duration(seconds: 5),
  });

  final ProcessSpawner spawner;
  final PortFile portFile;
  final HealthProbe health;
  final BackendLogSink log;
  final ProcessTreeKiller killTree;
  final SidecarResolver resolver;
  final Delay delay;
  final Clock clock;

  /// The current time, read only through the injected clock.
  DateTime get _now => clock();

  /// How long to wait for the sidecar to publish its port.
  final Duration portFileTimeout;

  /// How long to wait for `/health` to answer after the port is published.
  final Duration healthTimeout;

  /// The gap between readiness polls.
  final Duration pollInterval;

  /// How long to wait for a killed tree to actually disappear.
  final Duration cleanupTimeout;

  SidecarProcess? _process;
  bool _reused = false;
  SidecarStatus? _ready;
  Future<SidecarStatus>? _inFlight;

  /// The port in use, or null when not ready.
  int? get port => _ready?.port;

  /// The pid of the sidecar this launcher spawned, or null when reused or not
  /// running. Exposed for diagnostics and the real-process integration test.
  int? get processId => _process?.pid;

  @override
  Future<SidecarStatus> start() {
    // Duplicate-start prevention: an already-ready sidecar is returned as-is,
    // and concurrent callers share the one in-flight attempt.
    final SidecarStatus? ready = _ready;
    if (ready != null && ready.isReady) {
      return Future<SidecarStatus>.value(ready);
    }
    return _inFlight ??= _run().whenComplete(() => _inFlight = null);
  }

  Future<SidecarStatus> _run() async {
    // 1. Reuse a sidecar that is already running and healthy. The app is closed
    //    and reopened often, and the slow part is the Python cold start.
    final int? existing = await portFile.read();
    if (existing != null && existing > 0 && await health(existing)) {
      _reused = true;
      _ready = SidecarStatus.ready(port: existing, reused: true);
      await log.append(<String>[
        'sidecar: reusing running service on port $existing',
      ]);
      return _ready!;
    }

    // 2. Clear a stale port file so it cannot advertise a port this launch never
    //    binds.
    await portFile.delete();

    // 3. Resolve the runtime; a missing Python/entry point is a clear failure,
    //    not a crash.
    final SidecarSpawnSpec spec;
    try {
      spec = await resolver.resolve();
    } on SidecarUnavailableException catch (error) {
      final String safe = redactSecrets(error.message);
      await log.append(<String>['sidecar: $safe']);
      return _ready = SidecarStatus.failed(safe);
    }

    await log.append(<String>['sidecar: starting $spec']);

    // 4. Spawn.
    final SidecarProcess process;
    try {
      process = await spawner.spawn(spec);
    } catch (error) {
      final String message = redactSecrets('$error');
      await log.append(<String>['sidecar: could not start process: $message']);
      return _ready = SidecarStatus.failed(
        'The music service could not be started.',
      );
    }

    _process = process;
    _pump(process.stdout, 'out');
    _pump(process.stderr, 'err');

    // 5. Wait for the port file, watching for a premature exit.
    final int? boundPort = await _awaitPortFile(process);
    if (boundPort == null) {
      final SidecarStatus failure = _failedWithTail(
        process,
        'The music service did not start in time.',
      );
      await _stopTree(process);
      _process = null;
      return _ready = failure;
    }

    // 6. Confirm the service actually answers, not merely that it wrote a file.
    if (!await _awaitHealthy(process, boundPort)) {
      final SidecarStatus failure = _failedWithTail(
        process,
        'The music service did not become ready in time.',
      );
      await _stopTree(process);
      _process = null;
      return _ready = failure;
    }

    _ready = SidecarStatus.ready(port: boundPort);
    await log.append(<String>['sidecar: ready on port $boundPort']);
    return _ready!;
  }

  Future<int?> _awaitPortFile(SidecarProcess process) async {
    final DateTime deadline = _now.add(portFileTimeout);
    while (_now.isBefore(deadline)) {
      if (process.hasExited) return null;
      final int? published = await portFile.read();
      if (published != null && published > 0) return published;
      await delay(pollInterval);
    }
    return null;
  }

  Future<bool> _awaitHealthy(SidecarProcess process, int boundPort) async {
    final DateTime deadline = _now.add(healthTimeout);
    while (_now.isBefore(deadline)) {
      if (process.hasExited) return false;
      if (await health(boundPort)) return true;
      await delay(pollInterval);
    }
    return false;
  }

  SidecarStatus _failedWithTail(SidecarProcess process, String message) {
    final String reason = process.hasExited
        ? ' (process exited with code ${process.exitCode ?? 'unknown'})'
        : '';
    return SidecarStatus.failed('$message$reason');
  }

  /// Captures a stream into the bounded backend log. Each line is redacted, so
  /// a signed URL the backend might echo never lands in the log or the UI.
  void _pump(Stream<String> stream, String channel) {
    stream.listen(
      (String line) => unawaited(log.append(<String>[
        '[$channel] ${redactSecrets(line)}',
      ])),
      onError: (Object error) => unawaited(log.append(<String>[
        '[$channel] <stream error>',
      ])),
      cancelOnError: false,
    );
  }

  @override
  Future<void> shutdown() async {
    final SidecarProcess? process = _process;
    _process = null;
    _ready = null;
    _inFlight = null;
    final bool wasReused = _reused;
    _reused = false;

    if (wasReused || process == null) return;
    await _stopTree(process);
  }

  Future<void> _stopTree(SidecarProcess process) async {
    final int pid = process.pid;
    bool killed = false;
    try {
      killed = await killTree(pid).timeout(
        cleanupTimeout,
        onTimeout: () => false,
      );
    } catch (_) {
      killed = false;
    }

    // Verify the tree really went away, within a bounded window. This is
    // best-effort: `taskkill /T` can still miss a process Windows refuses to
    // let us touch, so the result is recorded rather than assumed.
    final DateTime deadline = _now.add(cleanupTimeout);
    while (!process.hasExited && _now.isBefore(deadline)) {
      await delay(pollInterval);
    }
    final bool gone = process.hasExited;
    await log.append(<String>[
      'sidecar: cleanup pid=$pid killed=$killed gone=$gone',
    ]);
  }

  static Future<void> _realDelay(Duration duration) =>
      Future<void>.delayed(duration);
  static DateTime _realNow() => DateTime.now();
}

/// A launcher that does nothing and reports ready.
///
/// This is the default so widget tests and goldens never spawn a process; the
/// composition root (`main.dart`) replaces it with the real lifecycle on
/// Windows.
class NoopSidecarLauncher implements SidecarLauncher {
  const NoopSidecarLauncher();

  @override
  Future<SidecarStatus> start() async => const SidecarStatus.ready();

  @override
  Future<void> shutdown() async {}
}
