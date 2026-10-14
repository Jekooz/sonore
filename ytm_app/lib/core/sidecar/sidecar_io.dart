import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'sidecar_launcher.dart';

/// The production dependencies for [SidecarLifecycle], kept in one place so the
/// orchestration stays platform-agnostic and fully fakeable in tests.

/// Wraps a `dart:io` [Process] in the testable [SidecarProcess] shape.
class IoSidecarProcess implements SidecarProcess {
  IoSidecarProcess(this._process) {
    // Completing a Future is how dart:io reports the exit; mirror it into the
    // synchronous flag the readiness loop reads.
    _process.exitCode.then((int code) => _exitCode = code);
  }

  final Process _process;
  int? _exitCode;

  @override
  int get pid => _process.pid;

  @override
  bool get hasExited => _exitCode != null;

  @override
  int? get exitCode => _exitCode;

  @override
  Stream<String> get stdout =>
      _process.stdout.transform(utf8.decoder).transform(const LineSplitter());

  @override
  Stream<String> get stderr =>
      _process.stderr.transform(utf8.decoder).transform(const LineSplitter());
}

/// Starts the sidecar with `Process.start`.
///
/// `runInShell` is false and the arguments are passed as a vector, so no shell
/// parses the path and nothing has to be quoted.
class IoProcessSpawner implements ProcessSpawner {
  const IoProcessSpawner();

  @override
  Future<SidecarProcess> spawn(SidecarSpawnSpec spec) async {
    final Process process = await Process.start(
      spec.executable,
      spec.arguments,
      workingDirectory: spec.workingDirectory,
      environment: spec.environment,
      runInShell: false,
      mode: ProcessStartMode.normal,
    );
    return IoSidecarProcess(process);
  }
}

/// The sidecar's published port file: `%TEMP%/ytmusic_sidecar_port.txt`, the
/// same location the Python service writes and the API client reads.
class FilePortFile implements PortFile {
  FilePortFile({File? file})
      : _file = file ??
            File(
              '${Directory.systemTemp.path}${Platform.pathSeparator}'
              'ytmusic_sidecar_port.txt',
            );

  final File _file;

  @override
  Future<int?> read() async {
    try {
      if (!await _file.exists()) return null;
      return int.tryParse((await _file.readAsString()).trim());
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> delete() async {
    try {
      if (await _file.exists()) await _file.delete();
    } catch (_) {
      // A stale port file is harmless: the health check already proved nothing
      // is serving on it.
    }
  }
}

/// Probes the existing `GET /health` endpoint and accepts only this app's own
/// answer (`{"status":"ok"}`), so a squatter on the port is not mistaken for the
/// sidecar.
Future<bool> httpHealthProbe(int port) async {
  final http.Client client = http.Client();
  try {
    final http.Response response = await client
        .get(Uri.parse('http://127.0.0.1:$port/health'))
        .timeout(const Duration(seconds: 2));
    return response.statusCode == 200 && response.body.contains('"ok"');
  } catch (_) {
    return false;
  } finally {
    client.close();
  }
}

/// Ending a process tree.
///
/// On Windows this is `taskkill /PID <pid> /T /F` (safe argument vector, bounded
/// timeout). On other platforms it falls back to signalling the pid. This is
/// best-effort by design: without a Job Object there is no guarantee every
/// descendant dies, which is recorded as a known limitation.
Future<bool> killProcessTree(int pid) async {
  if (!Platform.isWindows) {
    try {
      return Process.killPid(pid, ProcessSignal.sigkill);
    } catch (_) {
      return false;
    }
  }
  try {
    final ProcessResult result = await Process.run(
      'taskkill',
      <String>['/PID', '$pid', '/T', '/F'],
    ).timeout(const Duration(seconds: 5));
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// Appends backend output to `%TEMP%/ytmusic_backend.log`, rotating once past
/// [maxBytes] so the log cannot grow without bound.
class RotatingBackendLog implements BackendLogSink {
  RotatingBackendLog({File? file, this.maxBytes = 1 << 20})
      : _file = file ??
            File(
              '${Directory.systemTemp.path}${Platform.pathSeparator}'
              'ytmusic_backend.log',
            );

  final File _file;
  final int maxBytes;

  @override
  Future<void> append(Iterable<String> lines) async {
    final String text = lines.join('\n');
    if (text.isEmpty) return;
    try {
      if (_file.existsSync() && _file.lengthSync() > maxBytes) {
        _file.renameSync('${_file.path}.1');
      }
      _file.writeAsStringSync('$text\n', mode: FileMode.append);
    } catch (_) {
      // Logging must never prevent the app from starting.
    }
  }
}

/// Resolves the Python executable and the sidecar entry point.
///
/// Order: an explicit override, then `YTM_PYTHON` / `YTM_BACKEND_SCRIPT`, then
/// discovery. The script is found by walking up from the running executable (and
/// the current directory) to the repo folder that contains `backend/main.py`,
/// which works both from a packaged `build/…/Release` layout and from
/// `flutter run`.
class SystemSidecarResolver implements SidecarResolver {
  SystemSidecarResolver({
    this.pythonOverride,
    this.scriptOverride,
    this.environment,
  });

  final String? pythonOverride;
  final String? scriptOverride;

  /// Extra environment for the child (merged over the parent's), e.g. an
  /// explicit `YTM_PORT`. Null means inherit only.
  final Map<String, String>? environment;

  @override
  Future<SidecarSpawnSpec> resolve() async {
    final String? script = _resolveScript();
    if (script == null) {
      throw const SidecarUnavailableException(
        'The local music service (backend/main.py) could not be found.',
      );
    }

    final String configured = (pythonOverride ??
            Platform.environment['YTM_PYTHON'] ??
            '')
        .trim();
    final String executable = configured.isNotEmpty
        ? configured
        : (Platform.isWindows ? 'python' : 'python3');

    return SidecarSpawnSpec(
      executable: executable,
      arguments: <String>[script],
      workingDirectory: File(script).parent.path,
      environment: environment,
    );
  }

  String? _resolveScript() {
    final String configured = (scriptOverride ??
            Platform.environment['YTM_BACKEND_SCRIPT'] ??
            '')
        .trim();
    if (configured.isNotEmpty) {
      final File file = File(configured);
      if (file.existsSync()) return file.absolute.path;
      return null;
    }

    for (final Directory dir in _searchDirectories()) {
      final String candidate = _join(dir.path, 'main.py');
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// Candidate directories, nearest first: the ancestry of the running
  /// executable and of the current directory, deduplicated.
  Iterable<Directory> _searchDirectories() sync* {
    final Set<String> seen = <String>{};
    for (final Directory start in <Directory>[
      File(Platform.resolvedExecutable).parent,
      Directory.current,
    ]) {
      Directory? dir = start;
      for (int depth = 0; dir != null && depth < 8; depth++) {
        final String path = dir.absolute.path;
        if (seen.add(path)) {
          yield Directory(_join(path, 'backend'));
        }
        final Directory parent = dir.parent;
        if (parent.path == path) break;
        dir = parent;
      }
    }
  }

  static String _join(String dir, String name) =>
      '$dir${Platform.pathSeparator}$name';
}

/// Builds the real lifecycle wired to `dart:io`, `taskkill` and the sidecar's
/// published port file. Intended for the composition root only.
SidecarLauncher createSidecarLauncher({
  String? python,
  String? script,
  Map<String, String>? environment,
  File? portFile,
  File? logFile,
}) {
  return SidecarLifecycle(
    spawner: const IoProcessSpawner(),
    // portFile/logFile default to the production %TEMP% locations; a test passes
    // its own temp paths so it never touches the shared port file or log.
    portFile: FilePortFile(file: portFile),
    health: httpHealthProbe,
    log: RotatingBackendLog(file: logFile),
    killTree: killProcessTree,
    resolver: SystemSidecarResolver(
      pythonOverride: python,
      scriptOverride: script,
      environment: environment,
    ),
  );
}
