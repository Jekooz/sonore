import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ytm_app/core/sidecar/sidecar_io.dart';

/// Discovery of the sidecar's published port, against real files on disk.
///
/// This pins the contract that broke sign-in: the backend moved its port file
/// to `%LOCALAPPDATA%\Sonore\sidecar_port.txt`, but the launcher kept reading
/// only the old `%TEMP%` path, so it never saw the port a healthy service had
/// published and timed out — surfacing "the music service did not start in
/// time" over a service that was actually running.
void main() {
  late Directory sandbox;

  /// Joins path segments with the platform separator, so the assertions compare
  /// real separators rather than a Windows API quirk that happens to accept `/`.
  String path(List<String> segments) => segments.join(Platform.pathSeparator);

  File writePort(String file, String contents) {
    final File port = File(file);
    port.parent.createSync(recursive: true);
    port.writeAsStringSync(contents);
    return port;
  }

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('ytm_port_file');
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  group('published port discovery', () {
    test('reads the port the backend publishes under %LOCALAPPDATA%\\Sonore',
        () async {
      final String localAppData = path(<String>[sandbox.path, 'LocalAppData']);
      writePort(path(<String>[localAppData, 'Sonore', 'sidecar_port.txt']), '8000');

      final FilePortFile portFile = FilePortFile(
        files: FilePortFile.publishedPortFiles(
          localAppData: localAppData,
          tempDirectory: path(<String>[sandbox.path, 'Temp']),
        ),
      );

      expect(await portFile.read(), 8000);
    });

    test('falls back to the pre-1.6.1 %TEMP% file for an older service',
        () async {
      final String temp = path(<String>[sandbox.path, 'Temp']);
      writePort(path(<String>[temp, 'ytmusic_sidecar_port.txt']), '8137');

      final FilePortFile portFile = FilePortFile(
        files: FilePortFile.publishedPortFiles(
          localAppData: path(<String>[sandbox.path, 'LocalAppData']),
          tempDirectory: temp,
        ),
      );

      expect(await portFile.read(), 8137);
    });

    test('the current location wins when both files are present', () async {
      final String localAppData = path(<String>[sandbox.path, 'LocalAppData']);
      final String temp = path(<String>[sandbox.path, 'Temp']);
      writePort(path(<String>[localAppData, 'Sonore', 'sidecar_port.txt']), '8000');
      writePort(path(<String>[temp, 'ytmusic_sidecar_port.txt']), '8137');

      final FilePortFile portFile = FilePortFile(
        files: FilePortFile.publishedPortFiles(
          localAppData: localAppData,
          tempDirectory: temp,
        ),
      );

      expect(await portFile.read(), 8000);
    });

    test('an unreadable or absent port file is null, never a throw', () async {
      final FilePortFile portFile = FilePortFile(
        files: FilePortFile.publishedPortFiles(
          localAppData: path(<String>[sandbox.path, 'LocalAppData']),
          tempDirectory: path(<String>[sandbox.path, 'Temp']),
        ),
      );

      expect(await portFile.read(), isNull);
    });

    test('a stale port file is cleared from every candidate location', () async {
      final File local = writePort(
        path(<String>[
          sandbox.path,
          'LocalAppData',
          'Sonore',
          'sidecar_port.txt',
        ]),
        '8000',
      );
      final File fallback = writePort(
        path(<String>[sandbox.path, 'Temp', 'ytmusic_sidecar_port.txt']),
        '8137',
      );

      final FilePortFile portFile = FilePortFile(files: <File>[local, fallback]);
      await portFile.delete();

      expect(local.existsSync(), isFalse);
      expect(fallback.existsSync(), isFalse);
      expect(await portFile.read(), isNull);
    });

    test('an explicit file override is used verbatim', () async {
      final File explicit =
          writePort(path(<String>[sandbox.path, 'port.txt']), '8199');

      expect(await FilePortFile(file: explicit).read(), 8199);
    });
  });
}
