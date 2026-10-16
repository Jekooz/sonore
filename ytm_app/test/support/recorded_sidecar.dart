import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ytm_app/data/api_client.dart';
import 'package:ytm_app/data/ytm_repository.dart';

/// The payloads in `test/fixtures/` are the real sidecar's responses with every
/// identifying value rewritten: same keys, same types, same id prefixes, no real
/// names, ids, thumbnails or per-user tokens.
///
/// They are produced by `tool/anonymize_fixtures.py`, which fetches them from a
/// running, signed-in sidecar and anonymizes them so a public repository never
/// carries somebody's library. Regenerating is deterministic, so goldens stay
/// stable.
String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

/// A JSON 200 response, byte-for-byte as the sidecar would send it.
http.Response jsonOk(String body) => http.Response.bytes(
      utf8.encode(body),
      200,
      headers: const <String, String>{'content-type': 'application/json'},
    );

/// Routes each request to the recorded payload for that endpoint.
///
/// [responses] overrides individual paths, which is how the failure tests make
/// one endpoint return 401 or 502 while everything else keeps working.
MockClient recordedSidecar({
  Map<String, http.Response> responses = const <String, http.Response>{},
}) {
  return MockClient(
    (http.Request request) => recordedResponse(request, responses: responses),
  );
}

/// The recorded sidecar's routing, on its own.
///
/// Split out so a test can wrap it — recording the requests the app actually
/// sent while still answering with the real recorded payloads.
Future<http.Response> recordedResponse(
  http.Request request, {
  Map<String, http.Response> responses = const <String, http.Response>{},
}) async {
  final String path = request.url.path;
  final http.Response? override = responses[path];
  if (override != null) return override;

  final String name = switch (path) {
    '/health' => 'health.json',
    '/auth/status' => 'auth_status.json',
    '/account' => 'account.json',
    '/home' => 'home.json',
    '/library/songs' => 'library_songs.json',
    '/library/liked' => 'library_liked.json',
    '/library/playlists' => 'library_playlists.json',
    '/library/albums' => 'library_albums.json',
    '/library/artists' => 'library_artists.json',
    // The subscription list has the same row shape as the artist library, so
    // the same recorded payload answers it. (The POST toggle is written to the
    // same path; tests that assert the write inject their own client.)
    '/library/subscriptions' => 'library_artists.json',
    '/recommendations' => 'recommendations.json',
    '/search' => 'search.json',
    _ => '',
  };
  if (name.isNotEmpty) return jsonOk(fixture(name));

  if (path.startsWith('/album/')) return jsonOk(fixture('album.json'));
  if (path.startsWith('/playlist/')) return jsonOk(fixture('playlist.json'));
  if (path.startsWith('/artist/')) return jsonOk(fixture('artist.json'));
  if (path.startsWith('/stream/')) {
    return jsonOk(jsonEncode(<String, String>{
      'videoId': 'test',
      'url': 'https://stream.invalid/audio.m4a',
    }));
  }
  if (path == '/listening/events') {
    return jsonOk('{"recorded":true,"events":1}');
  }
  // The app's own listening store is empty on a machine that has never played
  // anything, which is exactly this shape. Tests that need rows override this
  // route; the populated shape itself is covered against the real store by
  // tests/test_recommendations.py.
  if (path == '/listening/history') {
    return jsonOk('{"entries":[],"count":0}');
  }
  if (path.startsWith('/ratings')) return jsonOk('{"ok":true}');
  // The folder the helper extension has to be loaded from. A fixed test path:
  // the app displays it and hands it to the folder-reveal seam, nothing more.
  if (path == '/auth/extension/folder') {
    return jsonOk(jsonEncode(<String, String>{
      'folder': r'C:\Program Files\Sonore\browser-extension',
    }));
  }
  return http.Response('{"detail":"not found"}', 404);
}

/// A repository whose sidecar is not running: every request fails to connect.
///
/// This is what makes the offline state reachable in a widget test instead of
/// only in a hand-composed golden.
YtmRepository offlineRepository() => YtmRepository(
      YtmApiClient(
        client: MockClient(
          (http.Request request) async =>
              throw const SocketException('connection refused'),
        ),
        readPortFile: () async => null,
      ),
    );

/// A repository whose sidecar is reachable but slow to answer.
///
/// Each probe resolves below the client's own 2s deadline but well after the
/// first frame, so the loading skeleton is on screen deterministically when a
/// test asserts it. Unlike a never-completing future this leaves no timer
/// pending: the answers arrive, the probe fails cleanly and the test can drain
/// the clock with a single pump.
YtmRepository pendingRepository() => YtmRepository(
      YtmApiClient(
        client: MockClient((http.Request request) async {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          // Not healthy, so discovery settles on the offline state rather than
          // leaving the app mid-probe when the test ends.
          return http.Response('{"detail":"starting"}', 503);
        }),
        readPortFile: () async => '8000',
      ),
    );

/// A repository whose sidecar is up but has no session.
YtmRepository signedOutRepository() => testRepository(
      responses: <String, http.Response>{
        '/auth/status': jsonOk('{"logged_in":false,"error":null}'),
      },
    );

/// A repository over the recorded payloads.
///
/// The port-file reader is injected because the real one does file I/O, and real
/// asynchronous I/O never completes under the widget-test clock — the discovery
/// future would hang and every screen would sit on its loading state forever.
YtmRepository testRepository({
  Map<String, http.Response> responses = const <String, http.Response>{},
}) =>
    YtmRepository(
      YtmApiClient(
        client: recordedSidecar(responses: responses),
        readPortFile: () async => '8000',
      ),
    );
