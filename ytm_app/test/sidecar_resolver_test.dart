import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ytm_app/core/sidecar/sidecar_io.dart';
import 'package:ytm_app/core/sidecar/sidecar_launcher.dart';

/// Resolution against real files on disk.
///
/// The sandbox is the layout the installer produces — the executable, the
/// sidecar, a private CPython and the sidecar's tools in one folder — built for
/// real in a temp directory, and the resolver under test is the production one.
/// Nothing here fakes the filesystem, so these tests state what a packaged app
/// will actually do: run on the runtime it shipped with, needing nothing
/// pre-installed, while still working from a repository checkout.
void main() {
  late Directory sandbox;
  late Directory app;

  String join(String parent, String child) =>
      '$parent${Platform.pathSeparator}$child';

  /// Creates a file at [relative] inside the app folder, parents included.
  ///
  /// The relative path is written with forward slashes and translated here, so
  /// the assertions below compare real separators rather than a Windows API
  /// quirk that happens to accept `/`.
  File place(String relative, [String contents = '']) {
    final File file = File(
      join(app.path, relative.split('/').join(Platform.pathSeparator)),
    );
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
    return file;
  }

  /// The production resolver, aimed at the sandbox instead of at wherever the
  /// test binary itself happens to live.
  SystemSidecarResolver resolver({
    String? python,
    String? script,
    Map<String, String>? environment,
  }) {
    return SystemSidecarResolver(
      pythonOverride: python,
      scriptOverride: script,
      environment: environment,
      executablePath: join(app.path, 'sonore.exe'),
      currentDirectory: sandbox.path,
    );
  }

  /// The parent's PATH, matched the way the resolver matches it: Windows
  /// spells the variable `Path` in the environment block.
  String inheritedPath() {
    for (final MapEntry<String, String> entry in Platform.environment.entries) {
      if (entry.key.toUpperCase() == 'PATH') return entry.value;
    }
    return '';
  }

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('ytm_resolver');
    app = Directory(join(sandbox.path, 'Sonore'))..createSync(recursive: true);
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  group('installed layout', () {
    test('uses the sidecar and the bundled CPython that ship in the app folder',
        () async {
      final File script = place('backend/main.py');
      final File python = place('python/python.exe');
      place('yt-dlp.exe');

      final SidecarSpawnSpec spec = await resolver().resolve();

      // The interpreter is the shipped one, never the machine's `python`.
      expect(spec.executable, python.path);
      expect(spec.executable, isNot('python'));
      expect(spec.arguments, <String>[script.path]);
      expect(spec.workingDirectory, script.parent.path);
    });

    test('puts the shipped tool folder on the child PATH, keeping the inherited '
        'one', () async {
      place('backend/main.py');
      place('python/python.exe');
      place('yt-dlp.exe');

      final SidecarSpawnSpec spec = await resolver().resolve();
      final String inherited = inheritedPath();
      final String expected = inherited.isEmpty
          ? app.path
          : '${app.path}${Platform.isWindows ? ';' : ':'}$inherited';

      // The sidecar finds yt-dlp with shutil.which, so this is what makes the
      // shipped copy visible to it — without dropping where the child already
      // looked.
      expect(spec.environment!['PATH'], expected);
    });

    test('a caller-supplied PATH is left alone', () async {
      place('backend/main.py');
      place('yt-dlp.exe');

      final SidecarSpawnSpec spec = await resolver(
        environment: <String, String>{'PATH': r'C:\only'},
      ).resolve();

      expect(spec.environment!['PATH'], r'C:\only');
    });

    test('the nearest app folder supplies each piece independently', () async {
      final File script = place('backend/main.py');
      final Directory tools = Directory(join(app.path, 'tools'))..createSync();
      final File python = File(join(join(tools.path, 'python'), 'python.exe'));
      python.parent.createSync(recursive: true);
      python.writeAsStringSync('');
      final File tool = File(join(tools.path, 'yt-dlp.exe'))
        ..writeAsStringSync('');

      final SidecarSpawnSpec spec = await SystemSidecarResolver(
        executablePath: join(tools.path, 'sonore.exe'),
        currentDirectory: sandbox.path,
      ).resolve();

      expect(spec.executable, python.path);
      expect(spec.arguments, <String>[script.path]);
      expect(spec.environment!['PATH']!.split(Platform.isWindows ? ';' : ':').first,
          tools.path);
      expect(tool.existsSync(), isTrue);
    });
  });

  group('overrides and fallbacks', () {
    test('an explicit interpreter override still wins over the bundled one',
        () async {
      place('backend/main.py');
      place('python/python.exe');

      final SidecarSpawnSpec spec =
          await resolver(python: r'C:\tools\python.exe').resolve();

      expect(spec.executable, r'C:\tools\python.exe');
    });

    test('a repository checkout with no bundled runtime uses the PATH python',
        () async {
      place('backend/main.py');

      final SidecarSpawnSpec spec = await resolver().resolve();

      expect(spec.executable, Platform.isWindows ? 'python' : 'python3');
    });

    test('with nothing shipped, the caller environment is passed through',
        () async {
      place('backend/main.py');

      final SidecarSpawnSpec spec = await resolver(
        environment: <String, String>{'YTM_PORT': '8199'},
      ).resolve();

      // No tool folder to add means no invented environment: the child inherits
      // the parent's, exactly as before the bundled runtime existed.
      expect(spec.environment, <String, String>{'YTM_PORT': '8199'});
    });

    test('and it stays null when the caller supplies nothing', () async {
      place('backend/main.py');

      expect((await resolver().resolve()).environment, isNull);
    });
  });

  group('failures stay clear', () {
    test('a missing sidecar is a clear failure, not a spawn guess', () async {
      expect(resolver().resolve(), throwsA(isA<SidecarUnavailableException>()));
    });

    test('a script override that does not exist fails instead of falling back',
        () async {
      // The entry point is right there, but an explicit override that is wrong
      // must not be silently ignored: the operator asked for a specific file.
      place('backend/main.py');

      expect(
        resolver(script: join(app.path, 'nope/main.py')).resolve(),
        throwsA(isA<SidecarUnavailableException>()),
      );
    });
  });

  group('the real spawner', () {
    test('a real child process ends up with the shipped tool folder on PATH',
        () async {
      // The whole point of the environment map is that the sidecar can find the
      // bundled yt-dlp. That only holds if the map survives the real spawn, so
      // this starts a real child through the same dart:io call the app uses and
      // asks that child what it sees. Windows spells the variable `Path` in the
      // inherited block, which is exactly the case this pins down.
      if (!Platform.isWindows) return;
      place('backend/main.py');
      place('yt-dlp.exe');

      final SidecarSpawnSpec spec = await resolver().resolve();
      final ProcessResult result = await Process.run(
        'cmd.exe',
        <String>['/c', 'echo %PATH%'],
        environment: spec.environment,
      );

      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(result.stdout.toString().trim().split(';').first, app.path);
    });
  });
}
