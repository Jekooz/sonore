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

/// The sidecar's published port file.
///
/// The backend writes `%LOCALAPPDATA%\Sonore\sidecar_port.txt`; the pre-1.6.1
/// `%TEMP%\ytmusic_sidecar_port.txt` is read as a fallback so a service started
/// by an older build is still discovered. This is the same discovery contract
/// the API client reads, so both halves of the app agree on the port.
class FilePortFile implements PortFile {
  FilePortFile({File? file, List<File>? files})
      : _files = files ?? (file != null ? <File>[file] : publishedPortFiles());

  /// The production locations of the published port, current contract first.
  ///
  /// Overridable so a test can point it at a sandbox instead of the shared
  /// per-user and temp directories.
  static List<File> publishedPortFiles({
    String? localAppData,
    String? tempDirectory,
  }) {
    final String? appData =
        localAppData ?? Platform.environment['LOCALAPPDATA'];
    final String temp = tempDirectory ?? Directory.systemTemp.path;
    return <File>[
      if (appData != null && appData.isNotEmpty)
        File(
          '$appData${Platform.pathSeparator}Sonore'
          '${Platform.pathSeparator}sidecar_port.txt',
        ),
      File('$temp${Platform.pathSeparator}ytmusic_sidecar_port.txt'),
    ];
  }

  final List<File> _files;

  @override
  Future<int?> read() async {
    for (final File file in _files) {
      try {
        if (!await file.exists()) continue;
        final int? port = int.tryParse((await file.readAsString()).trim());
        if (port != null) return port;
      } catch (_) {
        // Try the next candidate.
      }
    }
    return null;
  }

  @override
  Future<void> delete() async {
    for (final File file in _files) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {
        // A stale port file is harmless: the health check already proved
        // nothing is serving on it.
      }
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

/// Resolves the Python executable, the sidecar entry point and the child's
/// environment.
///
/// Precedence: an explicit override, then `YTM_PYTHON` / `YTM_BACKEND_SCRIPT`,
/// then discovery. The script is found by walking up from the running executable
/// (and the current directory) to the folder that contains `backend/main.py`,
/// which works both from a packaged `build/…/Release` layout and from
/// `flutter run`.
///
/// The layout the installer produces puts the sidecar, a private CPython and the
/// sidecar's tools beside the executable, and discovery prefers them:
///
///     <app>\sonore.exe
///     <app>\backend\main.py
///     <app>\python\python.exe
///     <app>\yt-dlp.exe
///
/// An installed app therefore runs on the runtime it shipped with and needs
/// nothing pre-installed, while a repository checkout still falls back to the
/// `python` on PATH. The bundled names are Windows-only by design, because the
/// installer is Windows-only.
class SystemSidecarResolver implements SidecarResolver {
  SystemSidecarResolver({
    this.pythonOverride,
    this.scriptOverride,
    this.environment,
    this.executablePath,
    this.currentDirectory,
  });

  final String? pythonOverride;
  final String? scriptOverride;

  /// Extra environment for the child (merged over the parent's), e.g. an
  /// explicit `YTM_PORT`. Null means inherit only.
  final Map<String, String>? environment;

  /// Where the walk up for the app folder starts, defaulting to the running
  /// executable. Injectable so a test can point it at a staged layout instead
  /// of depending on where the test binary itself happens to live.
  final String? executablePath;

  /// The second walk start, defaulting to the working directory.
  final String? currentDirectory;

  /// The interpreter the installer ships, relative to the app folder.
  static const String _bundledPythonDir = 'python';

  /// The console tool the sidecar shells out to, shipped beside the app. The
  /// sidecar resolves it with `shutil.which`, so the folder holding it has to be
  /// on the child's PATH (see [_childEnvironment]).
  static const String _bundledToolName = 'yt-dlp.exe';

  @override
  Future<SidecarSpawnSpec> resolve() async {
    final List<Directory> roots = _searchRoots().toList();

    final String? script = _resolveScript(roots);
    if (script == null) {
      throw const SidecarUnavailableException(
        'The local music service (backend/main.py) could not be found.',
      );
    }

    return SidecarSpawnSpec(
      executable: _resolveInterpreter(roots),
      arguments: <String>[script],
      workingDirectory: File(script).parent.path,
      environment: _childEnvironment(roots),
    );
  }

  /// An explicit interpreter wins, then the one the installer shipped, then
  /// whatever `python` the machine already has.
  ///
  /// The bundled runtime is deliberately ahead of PATH: the installed app then
  /// runs on the exact interpreter and packages it was built against, instead of
  /// silently using whichever Python the user happens to have installed.
  String _resolveInterpreter(List<Directory> roots) {
    final String configured = (pythonOverride ??
            Platform.environment['YTM_PYTHON'] ??
            '')
        .trim();
    if (configured.isNotEmpty) return configured;

    for (final Directory root in roots) {
      final String bundled =
          _join(_join(root.path, _bundledPythonDir), 'python.exe');
      if (File(bundled).existsSync()) return bundled;
    }

    return Platform.isWindows ? 'python' : 'python3';
  }

  String? _resolveScript(List<Directory> roots) {
    final String configured = (scriptOverride ??
            Platform.environment['YTM_BACKEND_SCRIPT'] ??
            '')
        .trim();
    if (configured.isNotEmpty) {
      final File file = File(configured);
      if (file.existsSync()) return file.absolute.path;
      return null;
    }

    for (final Directory root in roots) {
      final String candidate = _join(_join(root.path, 'backend'), 'main.py');
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// The caller's environment plus the folders that ship the sidecar's tools.
  ///
  /// The sidecar finds `yt-dlp` with `shutil.which`, so the folder holding the
  /// bundled copy has to be on the child's PATH — a child would otherwise
  /// inherit only the parent's PATH, which never contains the app folder. The
  /// inherited value is preserved, so this only widens where the sidecar looks.
  Map<String, String>? _childEnvironment(List<Directory> roots) {
    final List<String> toolDirs = <String>[];
    for (final Directory root in roots) {
      if (File(_join(root.path, _bundledToolName)).existsSync() &&
          !toolDirs.contains(root.path)) {
        toolDirs.add(root.path);
      }
    }
    if (toolDirs.isEmpty) return environment;

    final Map<String, String> child = <String, String>{...?environment};
    if (!child.keys.any((String key) => key.toUpperCase() == 'PATH')) {
      final String inherited = _inheritedPath();
      child['PATH'] = <String>[
        ...toolDirs,
        if (inherited.isNotEmpty) inherited,
      ].join(Platform.isWindows ? ';' : ':');
    }
    return child;
  }

  /// The parent's PATH, matched case-insensitively because Windows spells the
  /// variable `Path` in the environment block and Python reads it back as
  /// `PATH`.
  static String _inheritedPath() {
    for (final MapEntry<String, String> entry in Platform.environment.entries) {
      if (entry.key.toUpperCase() == 'PATH') return entry.value;
    }
    return '';
  }

  /// Candidate app folders, nearest first: the ancestry of the running
  /// executable and of the current directory, deduplicated.
  ///
  /// A candidate is a folder that may hold `backend/`, `python/` and the bundled
  /// tools — the repository layout and the installed layout alike.
  Iterable<Directory> _searchRoots() sync* {
    final Set<String> seen = <String>{};
    final String here = currentDirectory ?? Directory.current.path;
    for (final Directory start in <Directory>[
      File(executablePath ?? Platform.resolvedExecutable).parent,
      Directory(here),
    ]) {
      Directory? dir = start;
      for (int depth = 0; dir != null && depth < 8; depth++) {
        final String path = dir.absolute.path;
        if (seen.add(path)) yield dir;
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
