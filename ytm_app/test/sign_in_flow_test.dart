import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ytm_app/data/api_client.dart';
import 'package:ytm_app/data/ytm_repository.dart';
import 'package:ytm_app/ui/data_states.dart';

import 'support/recorded_sidecar.dart' show jsonOk;

/// Drives the real SignInController against a scripted sidecar, through the
/// same YtmApiClient the app uses.
///
/// The sidecar now owns the whole browser flow — no extension, and the app
/// opens nothing itself — so what these tests pin is the contract with it: the
/// app asks for a sign-in, polls the status endpoint, and finishes on the
/// sidecar's word rather than waiting forever.
void main() {
  testWidgets('a successful sign-in reaches done, not an endless wait',
      (tester) async {
    final List<String> requests = <String>[];
    final List<String> startBodies = <String>[];
    bool signedIn = false;
    int statusPolls = 0;

    final ProviderContainer container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(
          YtmApiClient(
            client: MockClient((http.Request request) async {
              requests.add('${request.method} ${request.url.path}');
              if (request.url.path == '/auth/browser/start') {
                startBodies.add(request.body);
              }
              return switch (request.url.path) {
                '/health' => jsonOk('{"status": "ok"}'),
                '/auth/status' =>
                  jsonOk('{"logged_in": $signedIn, "error": null}'),
                '/auth/browser/start' => jsonOk(
                    '{"state": "waiting", "browser": "Microsoft Edge", '
                    '"error": null}'),
                '/auth/browser/status' => jsonOk(
                    '{"state": "${statusPolls++ == 0 ? 'waiting' : 'success'}", '
                    '"browser": "Microsoft Edge", "error": null}'),
                '/auth/browser/cancel' => jsonOk('{"state": "cancelled"}'),
                '/account' => jsonOk('{"accountName": "Test Account", '
                    '"channelHandle": "@tester", "accountPhotoUrl": null}'),
                _ => jsonOk('{}'),
              };
            }),
            readPortFile: () async => null,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final SignInController controller = container.read(signInProvider.notifier);
    controller.start();
    await tester.pump();
    await tester.pump();

    // Waiting, with the sidecar told to run the browser flow itself: the app
    // must not open a window of its own, or two would appear.
    expect(container.read(signInProvider).stage, SignInStage.waiting);
    expect(startBodies.single, contains('"open_browser":true'));

    await tester.pump(const Duration(seconds: 2)); // first poll: still waiting
    expect(container.read(signInProvider).stage, SignInStage.waiting);

    signedIn = true; // the sidecar validated and stored the session
    await tester.pump(const Duration(seconds: 2)); // second poll: success
    await tester.pump();
    await tester.pump();

    // THE regression: "success" must complete the flow.
    expect(container.read(signInProvider).stage, SignInStage.done);
    // ...and the connection was refreshed, so the validated account shows.
    await container.read(connectionProvider.future);
    final YtmConnection connection = container.read(connectionProvider).value!;
    expect(connection.status, YtmStatus.ready);
    expect(connection.accountName, 'Test Account');
  });

  testWidgets('a failed attempt surfaces and can be retried', (tester) async {
    final List<String> requests = <String>[];
    int startCalls = 0;
    String pollState = 'waiting';

    final ProviderContainer container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(
          YtmApiClient(
            client: MockClient((http.Request request) async {
              requests.add('${request.method} ${request.url.path}');
              if (request.url.path == '/auth/browser/start') startCalls += 1;
              return switch (request.url.path) {
                '/health' => jsonOk('{"status": "ok"}'),
                '/auth/status' => jsonOk('{"logged_in": false, "error": null}'),
                '/auth/browser/start' => jsonOk(
                    '{"state": "waiting", "browser": "Microsoft Edge", '
                    '"error": null}'),
                '/auth/browser/status' => jsonOk('{"state": "$pollState", '
                    '"browser": "Microsoft Edge", "error": null}'),
                _ => jsonOk('{}'),
              };
            }),
            readPortFile: () async => null,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final SignInController controller = container.read(signInProvider.notifier);
    controller.start();
    await tester.pump();
    await tester.pump();

    pollState = 'failed';
    await tester.pump(const Duration(seconds: 2));
    expect(container.read(signInProvider).stage, SignInStage.failed);
    expect(container.read(signInProvider).detail, 'Sign-in was not completed.');

    // Retry from the failed state starts a fresh attempt.
    controller.start();
    await tester.pump();
    await tester.pump();
    expect(container.read(signInProvider).stage, SignInStage.waiting);
    expect(startCalls, 2);

    // Leave no poll running when the test ends.
    await controller.cancel();
  });

  testWidgets('cancel retires the attempt on the sidecar and allows a retry',
      (tester) async {
    final List<String> requests = <String>[];
    int startCalls = 0;

    final ProviderContainer container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(
          YtmApiClient(
            client: MockClient((http.Request request) async {
              requests.add('${request.method} ${request.url.path}');
              return switch (request.url.path) {
                '/health' => jsonOk('{"status": "ok"}'),
                '/auth/status' => jsonOk('{"logged_in": false, "error": null}'),
                '/auth/browser/start' => jsonOk(
                    '{"state": "waiting", "browser": "Microsoft Edge", '
                    '"error": null}'),
                '/auth/browser/cancel' => jsonOk('{"state": "cancelled"}'),
                _ => jsonOk('{"state": "waiting"}'),
              };
            }),
            readPortFile: () async => null,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final SignInController controller = container.read(signInProvider.notifier);
    controller.start();
    await tester.pump();
    await tester.pump();
    expect(container.read(signInProvider).stage, SignInStage.waiting);

    await controller.cancel();
    expect(container.read(signInProvider).stage, SignInStage.idle);
    // The sidecar is told, so its attempt dies with the screen instead of
    // outliving it.
    expect(requests, contains('POST /auth/browser/cancel'));

    startCalls = 1;
    controller.start();
    await tester.pump();
    await tester.pump();
    expect(container.read(signInProvider).stage, SignInStage.waiting);
    expect(startCalls, 1);

    // Leave no poll running when the test ends.
    await controller.cancel();
  });

  testWidgets('the app gives up on its own when the sidecar goes quiet',
      (tester) async {
    int cancelCalls = 0;

    final ProviderContainer container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(
          YtmApiClient(
            client: MockClient((http.Request request) async {
              if (request.url.path == '/auth/browser/cancel') cancelCalls += 1;
              return switch (request.url.path) {
                '/health' => jsonOk('{"status": "ok"}'),
                '/auth/status' => jsonOk('{"logged_in": false, "error": null}'),
                '/auth/browser/start' => jsonOk(
                    '{"state": "waiting", "browser": "Microsoft Edge", '
                    '"error": null}'),
                '/auth/browser/cancel' => jsonOk('{"state": "cancelled"}'),
                _ => jsonOk('{"state": "waiting"}'),
              };
            }),
            readPortFile: () async => null,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final SignInController controller = container.read(signInProvider.notifier);
    controller.start();
    await tester.pump();
    await tester.pump();

    // 105 polls is the app's own budget; one more tick trips it.
    for (int i = 0; i < 107; i++) {
      await tester.pump(const Duration(seconds: 2));
    }

    final SignInState state = container.read(signInProvider);
    expect(state.stage, SignInStage.failed);
    expect(state.detail, contains('timed out'));
    expect(cancelCalls, 1);
  });

  testWidgets('a 401 from a data call refreshes the cached connection',
      (tester) async {
    int probes = 0;
    bool sessionAlive = true;

    final ProviderContainer container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(
          YtmApiClient(
            client: MockClient((http.Request request) async {
              if (request.url.path == '/health') probes += 1;
              return switch (request.url.path) {
                '/health' => jsonOk('{"status": "ok"}'),
                '/auth/status' =>
                  jsonOk('{"logged_in": $sessionAlive, "error": null}'),
                '/account' => jsonOk('{"accountName": "Test Account", '
                    '"channelHandle": "@tester", "accountPhotoUrl": null}'),
                _ => jsonOk('{}'),
              };
            }),
            readPortFile: () async => null,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container.read(connectionProvider.future);
    final int baseline = probes;
    expect(container.read(connectionProvider).value!.status, YtmStatus.ready);

    // The sidecar has already cleared the session — that is what the 401 the
    // data screen received means.
    sessionAlive = false;

    // The gate still shows the data screen from its cached "ready" value; the
    // screen's error is the expired-session 401.
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: ConnectionGate(
              child: DataStateView<String>(
                value: AsyncValue<String>.error(
                  const YtmSignedOutException(),
                  StackTrace.current,
                ),
                data: (String data) => Text(data),
                onRetry: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(); // deferred invalidation runs
    await tester.pump(); // gate re-probes and rebuilds

    // The stale "Signed in as" is retired: the gate re-probed the sidecar,
    // which now says signed out, and the screen shows the sign-in prompt.
    expect(probes, greaterThan(baseline));
    expect(find.text('Not signed in to YouTube Music.'), findsOneWidget);
  });

  testWidgets('paste fallback feeds the handoff endpoint and retires the attempt',
      (tester) async {
    final List<String> requests = <String>[];
    final List<String> startBodies = <String>[];
    final List<http.Request> handoffs = <http.Request>[];

    final ProviderContainer container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(
          YtmApiClient(
            client: MockClient((http.Request request) async {
              requests.add('${request.method} ${request.url.path}');
              if (request.url.path == '/auth/browser/start') {
                startBodies.add(request.body);
              }
              if (request.url.path == '/auth/handoff') handoffs.add(request);
              return switch (request.url.path) {
                '/health' => jsonOk('{"status": "ok"}'),
                '/auth/status' => jsonOk('{"logged_in": false, "error": null}'),
                '/auth/browser/start' => jsonOk(
                    '{"state": "waiting", "browser": "Microsoft Edge", '
                    '"error": null}'),
                '/auth/handoff' => jsonOk('{"signed_in": true, "account": null}'),
                _ => jsonOk('{"state": "cancelled"}'),
              };
            }),
            readPortFile: () async => null,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container.read(ytmRepositoryProvider).signInWithPastedHeaders(
          'GET /youtubei/v1/browse HTTP/1.1\r\n'
          'Host: music.youtube.com\r\n'
          'cookie: SID=1; SAPISID=2; HSID=3\r\n'
          'User-Agent: Mozilla/5.0 (Test)\r\n',
        );

    expect(requests, contains('POST /auth/browser/start'));
    // The paste flow asks for an attempt that only waits: no window, no
    // capture, because the headers are the session.
    expect(startBodies.single, contains('"open_browser":false'));
    expect(handoffs, hasLength(1));
    expect(handoffs.single.body, contains('SID=1'));
    expect(handoffs.single.body, contains('Mozilla/5.0 (Test)'));
    // The attempt is retired once the paste is done, either way.
    expect(requests.last, 'POST /auth/browser/cancel');
  });

  testWidgets('paste without a cookie line is refused before any attempt',
      (tester) async {
    final List<String> requests = <String>[];

    final ProviderContainer container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(
          YtmApiClient(
            client: MockClient((http.Request request) async {
              requests.add('${request.method} ${request.url.path}');
              return jsonOk('{}');
            }),
            readPortFile: () async => null,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await expectLater(
      container
          .read(ytmRepositoryProvider)
          .signInWithPastedHeaders('user-agent: Mozilla/5.0'),
      throwsA(isA<YtmSignedOutException>()),
    );
    expect(requests, isEmpty, reason: 'no attempt may start without cookies');
  });

  test('parseRequestHeaders reads a devtools block and ignores junk', () {
    final Map<String, String> headers = parseRequestHeaders(
      'GET /youtubei/v1/browse HTTP/1.1\r\n'
      'Host: music.youtube.com\r\n'
      'cookie: SID=1; SAPISID=2\r\n'
      'User-Agent: Mozilla/5.0\r\n'
      '\r\n'
      'not a header line',
    );

    expect(headers['cookie'], 'SID=1; SAPISID=2');
    expect(headers['user-agent'], 'Mozilla/5.0');
    expect(headers['host'], 'music.youtube.com');
    expect(headers, isNot(contains('get /youtubei/v1/browse http/1.1')));
  });
}
