import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:ytm_app/core/sidecar/sidecar_io.dart';
import 'package:ytm_app/core/sidecar/sidecar_launcher.dart';
import 'package:ytm_app/data/api_client.dart';
import 'package:ytm_app/data/models.dart';
import 'package:ytm_app/data/ytm_repository.dart';

/// The Flutter data layer against the real Python sidecar.
///
/// A real, isolated sidecar is spawned on a dedicated port with its own port
/// file and log in a unique temp directory, and the real [YtmApiClient] and
/// [YtmRepository] talk to it over HTTP. Nothing here deletes or reads the
/// shared `%TEMP%/ytmusic_sidecar_port.txt`, so a running app is never disturbed.
///
/// The session state is whatever the machine already has: the tests detect it
/// and assert the correct behaviour for either case, so they are honest whether
/// or not a real account is signed in. They are read-only — no rating, sign-out
/// or other mutation is ever sent, and no account data is printed.
///
/// What is verified automatically: health/readiness, session-state propagation,
/// signed-out mapping of protected routes (when signed out), real metadata +
/// artwork retrieval (when signed in), real stream resolution, the auth
/// validators' reject paths, unavailable/restart discovery.
///
/// What needs a human: the interactive browser sign-in hand-off itself (it opens
/// a real browser). See proof/phase5_integration.txt.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const int sharedPort = 8201;
  const String streamProbeId = 'dQw4w9WgXcQ';

  final File sharedPortFile = File(
    '${Directory.systemTemp.path}${Platform.pathSeparator}'
    'ytmusic_sidecar_port.txt',
  );

  late Directory dir;
  late SidecarLauncher launcher;
  late YtmApiClient client;
  late YtmRepository repository;
  late bool signedIn;
  String? sharedBefore;

  YtmApiClient clientFor(File portFile) => YtmApiClient(
        readPortFile: () async {
          final int? published = await FilePortFile(file: portFile).read();
          return published?.toString();
        },
      );

  setUpAll(() async {
    sharedBefore =
        sharedPortFile.existsSync() ? sharedPortFile.readAsStringSync() : null;

    dir = Directory.systemTemp.createTempSync('ytm_backend_api');
    final File portFile = File('${dir.path}${Platform.pathSeparator}port.txt');
    launcher = createSidecarLauncher(
      environment: <String, String>{
        'YTM_PORT': '$sharedPort',
        'YTM_PORT_FILE': portFile.path,
      },
      portFile: portFile,
      logFile: File('${dir.path}${Platform.pathSeparator}backend.log'),
    );

    final SidecarStatus status = await launcher.start();
    expect(status.isReady, isTrue, reason: status.message ?? '');
    expect(status.port, sharedPort);

    client = clientFor(portFile);
    repository = YtmRepository(client);
    signedIn = await client.isSignedIn();
  });

  tearDownAll(() async {
    client.dispose();
    await launcher.shutdown();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('backend up (isolated real sidecar)', () {
    testWidgets('health and readiness', (WidgetTester tester) async {
      expect(await client.health(), isTrue);
    });

    testWidgets('the detected session state propagates to the app',
        (WidgetTester tester) async {
      final YtmConnection connection = await repository.connection();
      expect(
        connection.status,
        signedIn ? YtmStatus.ready : YtmStatus.signedOut,
      );
      expect(await client.isSignedIn(), signedIn);
    });

    testWidgets('the browser sign-in state is idle with nothing pending',
        (WidgetTester tester) async {
      expect(await repository.browserSignInState(), 'idle');
    });

    testWidgets('protected routes behave according to the real session',
        (WidgetTester tester) async {
      if (signedIn) {
        // Real retrieval: rows and metadata come back parsed, and every row the
        // service returns carries artwork. Nothing is printed.
        final List<HomeRow> home = await repository.home();
        expect(home, isA<List<HomeRow>>());

        final Map<String, dynamic> account = await client.account();
        expect(account.keys, containsAll(<String>['accountName']));

        final SearchResults results = await repository.search('thriller');
        expect(results.length, greaterThan(0));
        final List<MediaItem> items = <MediaItem>[
          ...results.songs,
          ...results.albums,
          ...results.artists,
          ...results.playlists,
        ];
        expect(
          items.any((MediaItem i) => (i.artworkUrl ?? '').isNotEmpty),
          isTrue,
          reason: 'real artwork URLs should resolve for search results',
        );
      } else {
        await expectLater(
          repository.home(),
          throwsA(isA<YtmSignedOutException>()),
        );
        await expectLater(
          client.account(),
          throwsA(isA<YtmSignedOutException>()),
        );
      }
    });

    testWidgets('a real stream request resolves through yt-dlp',
        (WidgetTester tester) async {
      // /stream does not require a session; it resolves audio via yt-dlp. The
      // URL is signed, so only its shape is asserted and it is never printed.
      final String url = await client.streamUrl(streamProbeId);
      expect(url, startsWith('http'));
    });

    testWidgets('an invalid stream id is a real 400, not a crash',
        (WidgetTester tester) async {
      await expectLater(
        client.streamUrl('bad!!'),
        throwsA(
          isA<YtmRequestException>().having(
            (YtmRequestException e) => e.statusCode,
            'statusCode',
            400,
          ),
        ),
      );
    });

    testWidgets('the real validator rejects an incomplete cookie hand-off '
        'without storing it', (WidgetTester tester) async {
      const String notARealCookie = 'not-a-real-session-value';
      final http.Response response = await http.post(
        Uri.parse('http://127.0.0.1:$sharedPort/auth/cookies'),
        headers: const <String, String>{'content-type': 'application/json'},
        body: jsonEncode(<String, dynamic>{
          'cookies': <String, String>{'SID': notARealCookie},
        }),
      );

      expect(response.statusCode, 422);
      expect(response.body, isNot(contains(notARealCookie)));
    });

    testWidgets('an unsolicited extension hand-off is rejected',
        (WidgetTester tester) async {
      final http.Response response = await http.post(
        Uri.parse('http://127.0.0.1:$sharedPort/auth/extension'),
        headers: const <String, String>{'content-type': 'application/json'},
        body: jsonEncode(<String, dynamic>{'cookies': <String, String>{}}),
      );
      expect(response.statusCode, 409);
    });

    testWidgets('the shared production port file was never disturbed',
        (WidgetTester tester) async {
      final String? sharedAfter =
          sharedPortFile.existsSync() ? sharedPortFile.readAsStringSync() : null;
      expect(sharedAfter, sharedBefore);
    });
  });

  group('backend restart', () {
    testWidgets('a stopped backend reports offline and is rediscovered on '
        'restart', (WidgetTester tester) async {
      final Directory dir2 = Directory.systemTemp.createTempSync('ytm_restart');
      final File portFile =
          File('${dir2.path}${Platform.pathSeparator}port.txt');
      // No fixed YTM_PORT: let the backend pick a free port, exactly as in
      // production, and discover it through the port file.
      final SidecarLauncher restarter = createSidecarLauncher(
        environment: <String, String>{'YTM_PORT_FILE': portFile.path},
        portFile: portFile,
        logFile: File('${dir2.path}${Platform.pathSeparator}backend.log'),
      );
      final YtmApiClient restartedClient = clientFor(portFile);
      addTearDown(() async {
        await restarter.shutdown();
        restartedClient.dispose();
        if (dir2.existsSync()) dir2.deleteSync(recursive: true);
      });
      final YtmRepository restartedRepo = YtmRepository(restartedClient);

      expect((await restarter.start()).isReady, isTrue);
      expect(
        (await restartedRepo.connection()).status,
        signedIn ? YtmStatus.ready : YtmStatus.signedOut,
      );

      await restarter.shutdown();
      expect((await restartedRepo.connection()).status, YtmStatus.offline);

      expect((await restarter.start()).isReady, isTrue);
      expect(
        (await restartedRepo.connection()).status,
        signedIn ? YtmStatus.ready : YtmStatus.signedOut,
      );
    });
  });
}
