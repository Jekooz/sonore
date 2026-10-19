import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Why a request could not be satisfied. The three cases are deliberately
/// distinct, because the screen must say something different for each: a
/// sidecar that is not running is not the same thing as a session that has
/// expired, and neither is the same as a failed request.
sealed class YtmException implements Exception {
  const YtmException();

  /// A short sentence that is safe to show the user.
  String get message;
}

/// The sidecar is not running (or not reachable). Nothing is cached locally, so
/// the honest thing to say is that the service is offline.
class YtmOfflineException extends YtmException {
  const YtmOfflineException();

  @override
  String get message => 'YouTube Music is not reachable.';
}

/// The sidecar is running but has no usable session: the user has to sign in.
class YtmSignedOutException extends YtmException {
  const YtmSignedOutException([this.detail]);

  final String? detail;

  @override
  String get message => detail ?? 'Not signed in to YouTube Music.';
}

/// A request reached the sidecar and failed, or returned something unusable.
class YtmRequestException extends YtmException {
  const YtmRequestException(this.message, {this.statusCode});

  @override
  final String message;

  final int? statusCode;
}

/// HTTP client for the existing FastAPI sidecar (`backend/main.py`).
///
/// Credential rule (project non-negotiable, design.md section 3.I): this client
/// never receives, stores or logs cookies, session values or signed stream URLs.
/// The sidecar owns the session in the Windows Credential Locker; the app only
/// asks it for state and rows. Stream URLs are handed straight to the audio
/// layer and are never printed, stored in state, or put in an error message.
/// Reads the sidecar's published port, or null when the file is absent.
///
/// This is a seam, not indirection for its own sake: the lookup is real file
/// I/O, and real asynchronous I/O does not progress under the widget-test clock,
/// so a test that reached this would wait forever on a Future that can never
/// complete. Tests inject a reader that answers immediately.
typedef PortFileReader = Future<String?> Function();

class YtmApiClient {
  YtmApiClient({http.Client? client, PortFileReader? readPortFile})
      : _client = client ?? http.Client(),
        _readPortFile = readPortFile ?? _readPublishedPort;

  final http.Client _client;
  final PortFileReader _readPortFile;

  /// Override for the emulator/host case:
  /// `--dart-define=YTM_BASE_URL=http://10.0.2.2:8000`.
  static const String _baseUrlOverride = String.fromEnvironment('YTM_BASE_URL');

  String? _baseUrl;

  /// The base URL in use, or null before the first successful [connect].
  String? get baseUrl => _baseUrl;

  bool get isConnected => _baseUrl != null;

  /// The per-install API token the sidecar requires on every account/stream
  /// route (header `X-Sonore-Token`). Fetched once from the sidecar's own
  /// `/auth/install-token` and then attached automatically; the app never
  /// shows or logs it except through the explicit Settings copy button.
  String? _apiToken;

  /// The token in use, or null before the first successful fetch.
  String? get apiToken => _apiToken;

  /// True while a token fetch is in flight. The fetch is a plain HTTP call on
  /// purpose: routing it through [_send] would call [connect], which calls back
  /// into [_ensureToken], and the two would recurse forever.
  bool _fetchingToken = false;

  /// Deadlines per call shape: a search or home feed is a few seconds, but
  /// resolving a stream runs yt-dlp on the sidecar and is measurably slower.
  static const Duration _dataTimeout = Duration(seconds: 30);
  static const Duration _streamTimeout = Duration(seconds: 90);
  static const Duration _connectTimeout = Duration(seconds: 2);

  /// Finds the sidecar and remembers its base URL.
  ///
  /// The sidecar picks a free port in 8000-8099 at boot and publishes it to
  /// `%LOCALAPPDATA%\Sonore\sidecar_port.txt` — per-user, outside the app
  /// folder and %TEMP%. The old `%TEMP%/ytmusic_sidecar_port.txt` is still
  /// read as a fallback so an older sidecar keeps working. Android has no
  /// on-device sidecar, so the host loopback address is tried there instead.
  Future<String?> connect() async {
    for (final String candidate in await _candidates()) {
      if (await _isHealthy(candidate)) {
        _baseUrl = candidate;
        await _ensureToken();
        return candidate;
      }
    }
    _baseUrl = null;
    return null;
  }

  /// Reads the published port file. The current location is
  /// `%LOCALAPPDATA%\Sonore\sidecar_port.txt`; the pre-1.6.1
  /// `%TEMP%/ytmusic_sidecar_port.txt` is the fallback. An unreadable
  /// directory is not fatal: the fixed-port fallbacks still have a chance.
  static Future<String?> _readPublishedPort() async {
    final List<String> directories = <String>[
      if (Platform.environment['LOCALAPPDATA'] != null)
        '${Platform.environment['LOCALAPPDATA']}${Platform.pathSeparator}Sonore',
      Directory.systemTemp.path,
    ];
    const List<String> names = <String>[
      'sidecar_port.txt',
      'ytmusic_sidecar_port.txt',
    ];
    for (final String directory in directories) {
      for (final String name in names) {
        try {
          final File file = File('$directory${Platform.pathSeparator}$name');
          if (!await file.exists()) continue;
          final String value = (await file.readAsString()).trim();
          if (value.isNotEmpty) return value;
        } catch (_) {
          // Try the next candidate path.
        }
      }
    }
    return null;
  }

  /// Fetches the per-install API token once and keeps it for later calls.
  ///
  /// Best effort: a sidecar that cannot answer here will surface the real
  /// problem on the request that follows, so this never throws. It talks to
  /// [_baseUrl] directly (no [_send]) because the request that triggered the
  /// fetch is already inside `_send`; going through it would recurse.
  Future<void> _ensureToken() async {
    if (_apiToken != null || _fetchingToken) return;
    final String? base = _baseUrl;
    if (base == null) return; // Not connected yet; connect() fetches it.

    _fetchingToken = true;
    try {
      final http.Response response = await _client
          .get(Uri.parse('$base/auth/install-token'))
          .timeout(_connectTimeout);
      if (response.statusCode == 200) {
        final dynamic decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is Map<String, dynamic>) {
          _apiToken = decoded['install_token'] as String?;
        }
      }
    } catch (_) {
      // Leave it null; the actual request surfaces the real failure.
    } finally {
      _fetchingToken = false;
    }
  }

  /// The per-install token, fetched if needed. Used by Settings to show and
  /// copy the value, and attached automatically to every locked route.
  Future<String?> installToken() async {
    if (_baseUrl == null) await connect();
    await _ensureToken();
    return _apiToken;
  }

  /// The header every locked route expects, or nothing before the fetch lands.
  Map<String, String> _authHeaders() => _apiToken == null
      ? const <String, String>{}
      : <String, String>{'X-Sonore-Token': _apiToken!};

  Future<List<String>> _candidates() async {
    final List<String> candidates = <String>[];
    if (_baseUrlOverride.isNotEmpty) candidates.add(_baseUrlOverride);

    final String? published = await _readPortFile();
    if (published != null && int.tryParse(published) != null) {
      candidates.add('http://127.0.0.1:$published');
    }

    if (Platform.isAndroid) candidates.add('http://10.0.2.2:8000');
    candidates.add('http://127.0.0.1:8000');
    return candidates;
  }

  Future<bool> _isHealthy(String base) async {
    try {
      final http.Response response = await _client
          .get(Uri.parse('$base/health'))
          .timeout(_connectTimeout);
      return response.statusCode == 200 && response.body.contains('"ok"');
    } catch (_) {
      return false;
    }
  }

  /// Runs [request] against the sidecar, discovering it first if needed.
  ///
  /// A connection failure drops the remembered base URL and retries once, so a
  /// sidecar that restarted on a different port is picked up without a relaunch.
  Future<http.Response> _send(
    Future<http.Response> Function(String base) request, {
    required Duration timeout,
  }) async {
    if (_baseUrl == null && await connect() == null) {
      throw const YtmOfflineException();
    }

    try {
      return await request(_baseUrl!).timeout(timeout);
    } on YtmException {
      rethrow;
    } catch (_) {
      // Either the first attempt failed or the remembered URL is stale.
      _baseUrl = null;
      if (await connect() == null) throw const YtmOfflineException();
      try {
        return await request(_baseUrl!).timeout(timeout);
      } on YtmException {
        rethrow;
      } catch (_) {
        throw const YtmOfflineException();
      }
    }
  }

  Future<dynamic> _getJson(String path, {Duration? timeout}) async {
    await _ensureToken();
    final http.Response response = await _send(
      (String base) =>
          _client.get(Uri.parse('$base$path'), headers: _authHeaders()),
      timeout: timeout ?? _dataTimeout,
    );
    return _decode(response, path);
  }

  Future<dynamic> _postJson(
    String path,
    Map<String, dynamic> body, {
    Duration? timeout,
    Map<String, String> extraHeaders = const <String, String>{},
  }) async {
    await _ensureToken();
    final http.Response response = await _send(
      (String base) => _client.post(
        Uri.parse('$base$path'),
        headers: <String, String>{
          'Content-Type': 'application/json',
          ..._authHeaders(),
          ...extraHeaders,
        },
        body: jsonEncode(body),
      ),
      timeout: timeout ?? _dataTimeout,
    );
    return _decode(response, path);
  }

  dynamic _decode(http.Response response, String path) {
    if (response.statusCode == 200) {
      try {
        return jsonDecode(utf8.decode(response.bodyBytes));
      } catch (_) {
        throw YtmRequestException(
          'The music service returned an unreadable response.',
          statusCode: response.statusCode,
        );
      }
    }

    final String? detail = _detailOf(response.body);

    // 401 is the sidecar saying the stored session is no longer usable.
    if (response.statusCode == 401) {
      throw YtmSignedOutException(detail);
    }
    // 422 is an incomplete sign-in (see /auth/cookies), which is still a
    // sign-in problem rather than a request failure.
    if (response.statusCode == 422) {
      throw YtmSignedOutException(detail);
    }
    // 502/503/504 mean the sidecar is up but the upstream music service (or
    // yt-dlp) failed; that is retryable, so it stays a request error.
    throw YtmRequestException(
      detail ?? 'The music service request failed (${response.statusCode}).',
      statusCode: response.statusCode,
    );
  }

  /// The sidecar's own message, when it sent one, minus any URL in it.
  String? _detailOf(String body) {
    try {
      final dynamic decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final dynamic detail = decoded['detail'];
        if (detail is String && detail.trim().isNotEmpty) {
          return _stripUrls(detail.trim());
        }
      }
    } catch (_) {
      // Not JSON; fall through to the caller's generic message.
    }
    return null;
  }

  /// Belt and braces: a sidecar detail line must never carry a signed URL into
  /// the UI or a log.
  static String _stripUrls(String value) =>
      value.replaceAll(RegExp(r'https?://\S+'), '<url>');

  // ------------------------------------------------------------- endpoints ---

  /// GET /health
  Future<bool> health() async {
    try {
      final http.Response response = await _send(
        (String base) => _client.get(Uri.parse('$base/health')),
        timeout: _connectTimeout,
      );
      return response.statusCode == 200;
    } on YtmException {
      return false;
    }
  }

  /// GET /auth/status -> {"logged_in": bool, "error": str|null}
  Future<bool> isSignedIn() async {
    final dynamic body = await _getJson('/auth/status');
    if (body is Map<String, dynamic>) return body['logged_in'] == true;
    return false;
  }

  /// GET /account -> {accountName, channelHandle, accountPhotoUrl}
  Future<Map<String, dynamic>> account() async =>
      _asMap(await _getJson('/account'));

  /// GET /home -> [{title, contents: [...]}], rows with no content removed by
  /// the sidecar already.
  Future<List<dynamic>> home() async => _asList(await _getJson('/home'));

  /// GET /library/{segment}
  Future<List<dynamic>> library(String segment) async =>
      _asList(await _getJson('/library/$segment'));

  /// GET /library/subscriptions -> the artist channels the account follows.
  Future<List<dynamic>> subscriptions() async =>
      _asList(await _getJson('/library/subscriptions'));

  /// POST /library/subscriptions — follow or unfollow one artist.
  ///
  /// A real account change, not a local flag: the sidecar calls ytmusicapi's
  /// `subscribe_artist` / `unsubscribe_artists`, so the subscription lands on
  /// the user's YouTube Music account (and the Follow button can read it back).
  Future<void> setArtistSubscribed(String artistId, bool subscribed) async {
    await _postJson('/library/subscriptions', <String, dynamic>{
      'artistId': artistId,
      'subscribed': subscribed,
    });
  }

  /// GET /search?q=&filter= — real ytmusicapi search. Without [filter] the
  /// result list is mixed and every row carries its own `resultType`.
  Future<List<dynamic>> search(String query, {String? filter}) async {
    final Uri uri = Uri(
      path: '/search',
      queryParameters: <String, String>{
        'q': query,
        if (filter != null && filter.isNotEmpty) 'filter': filter,
      },
    );
    return _asList(await _getJson(uri.toString()));
  }

  /// GET /album/{browseId}
  Future<Map<String, dynamic>> album(String browseId) async =>
      _asMap(await _getJson('/album/${Uri.encodeComponent(browseId)}'));

  /// GET /playlist/{playlistId}
  Future<Map<String, dynamic>> playlist(String playlistId) async =>
      _asMap(await _getJson('/playlist/${Uri.encodeComponent(playlistId)}'));

  /// GET /artist/{channelId}
  Future<Map<String, dynamic>> artist(String channelId) async =>
      _asMap(await _getJson('/artist/${Uri.encodeComponent(channelId)}'));

  /// GET /stream/{videoId} -> {"videoId":…, "url":…}.
  ///
  /// The URL is short-lived and signed; it is returned straight to the audio
  /// layer and never logged, stored or included in an exception.
  Future<String> streamUrl(String videoId) async {
    final dynamic body = await _getJson(
      '/stream/${Uri.encodeComponent(videoId)}',
      timeout: _streamTimeout,
    );
    final Map<String, dynamic> map = _asMap(body);
    final String? url = map['url'] as String?;
    if (url == null || url.isEmpty) {
      throw const YtmRequestException('No stream is available for that track.');
    }
    return url;
  }

  /// GET /prefetch/{videoId} — warms the sidecar's own stream cache. Best
  /// effort: a failure here is not the user's problem, so it is swallowed.
  Future<void> prefetch(String videoId) async {
    try {
      await _ensureToken();
      await _send(
        (String base) => _client.get(
          Uri.parse('$base/prefetch/${Uri.encodeComponent(videoId)}'),
          headers: _authHeaders(),
        ),
        timeout: _dataTimeout,
      );
    } on YtmException {
      // Prefetch is an optimisation only.
    }
  }

  /// GET /recommendations?seed=&limit=&exclude= — real ranked candidates for
  /// the Autoplay refill.
  ///
  /// [exclude] is the current queue (bounded by the sidecar), so the service
  /// never hands back something that is already playing, and the seed itself is
  /// filtered out server-side.
  Future<List<dynamic>> recommendations(
    String seed, {
    int limit = 12,
    List<String> exclude = const <String>[],
  }) async {
    final Uri uri = Uri(
      path: '/recommendations',
      queryParameters: <String, String>{
        'seed': seed,
        'limit': '$limit',
        if (exclude.isNotEmpty) 'exclude': exclude.join(','),
      },
    );
    final Map<String, dynamic> body = _asMap(await _getJson(uri.toString()));
    final dynamic tracks = body['tracks'];
    return tracks is List ? tracks : const <dynamic>[];
  }

  /// GET /listening/history?limit= — the tracks this app played, newest first.
  ///
  /// This is the app's own record (the same store the ranker reads); it is not
  /// a claim about the account's service-side history.
  Future<List<dynamic>> listeningHistory({int limit = 30}) async {
    final Uri uri = Uri(
      path: '/listening/history',
      queryParameters: <String, String>{'limit': '$limit'},
    );
    final Map<String, dynamic> body = _asMap(await _getJson(uri.toString()));
    final dynamic entries = body['entries'];
    return entries is List ? entries : const <dynamic>[];
  }

  /// POST /listening/events — one aggregated playback event, sent when a track
  /// is left rather than on every position tick.
  ///
  /// Best effort by design: history is a ranking signal for recommendations, so
  /// a sidecar that is down or a store that refuses the write must not turn a
  /// finished song into an error the listener has to dismiss.
  Future<void> reportListeningEvent(Map<String, dynamic> event) async {
    try {
      await _postJson('/listening/events', event);
    } on YtmException {
      // Ranking signal only; nothing on screen depends on it succeeding.
    }
  }

  /// POST /auth/browser/start — begins a sign-in (2 s poll, 3 min timeout on
  /// the sidecar). The sidecar owns the whole flow: it signs in from an
  /// already signed-in profile with no window at all, or opens the browser the
  /// user set as default in Windows — their own Firefox profile, or a Chromium
  /// in a profile it owns — for them to sign in there. Nothing is installed and
  /// no extension is involved.
  ///
  /// `openBrowser: false` starts an attempt that only waits for a hand-off,
  /// which is what the paste-headers fallback needs.
  ///
  /// The response carries the state, the browser in use and the sidecar's
  /// optional error text. Only session state crosses the wire; no cookie
  /// material ever reaches this client.
  Future<Map<String, dynamic>> startBrowserSignIn({
    bool openBrowser = true,
  }) async =>
      _asMap(
        await _postJson(
          '/auth/browser/start',
          <String, dynamic>{'open_browser': openBrowser},
        ),
      );

  /// GET /auth/browser/status -> idle|waiting|success|failed|cancelled
  Future<String> browserSignInState() async =>
      _stateOf(await _getJson('/auth/browser/status'));

  /// POST /auth/browser/cancel
  Future<void> cancelBrowserSignIn() async =>
      _postJson('/auth/browser/cancel', const <String, dynamic>{});

  /// POST /auth/handoff — the Settings "paste request headers" fallback.
  ///
  /// The sidecar recovers the cookie line from the pasted headers, validates
  /// the candidate against YouTube and only then stores it, exactly like a
  /// session it captured itself. Authenticated by the per-install token, which
  /// [_authHeaders] already attaches.
  Future<void> handoff({required Map<String, String> headers}) async =>
      _postJson(
        '/auth/handoff',
        <String, dynamic>{'headers': headers},
      );

  /// GET /auth/browser/info -> {"browser": name}
  ///
  /// The browser sign-in will use: whatever the user set as default in Windows
  /// when that can be used, otherwise the Edge or Chrome every machine has.
  /// Cosmetic: it only message-brands the wait.
  Future<String> defaultBrowser() async {
    try {
      final dynamic body = await _getJson('/auth/browser/info');
      if (body is Map<String, dynamic>) {
        return (body['browser'] as String?) ?? 'your browser';
      }
    } on YtmException {
      // A friendly name is cosmetic; the flow does not depend on it.
    }
    return 'your browser';
  }

  String _stateOf(dynamic body) {
    if (body is Map<String, dynamic>) {
      return (body['state'] as String?) ?? 'unknown';
    }
    return 'unknown';
  }

  /// GET /lyrics/{videoId} -> real lyrics, timestamped when YouTube supplies
  /// them.
  ///
  /// Returns null when the service says there are none — an answer, not a
  /// failure, so the screen can say "no lyrics" instead of showing an error.
  Future<Map<String, dynamic>?> lyrics(String videoId) async {
    try {
      final dynamic body = await _getJson(
        '/lyrics/${Uri.encodeComponent(videoId)}',
        timeout: _dataTimeout,
      );
      return _asMap(body);
    } on YtmRequestException catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    }
  }

  /// POST /auth/signout — forget the stored session on the sidecar.
  Future<void> signOut() async {
    await _postJson('/auth/signout', const <String, dynamic>{});
  }

  /// GET /playback/engine -> {version, source, path, update}. The playback
  /// engine is the bundled (or updated) yt-dlp the sidecar uses to resolve
  /// stream URLs; Settings shows its version and the last update result.
  Future<Map<String, dynamic>> playbackEngine() async =>
      _asMap(await _getJson('/playback/engine'));

  /// POST /playback/engine/update — refresh yt-dlp in the background. The
  /// caller re-reads [playbackEngine] to see the result once it lands.
  Future<void> updatePlaybackEngine() async {
    await _postJson('/playback/engine/update', const <String, dynamic>{});
  }

  /// POST /ratings — real like/dislike via ytmusicapi's rate_song.
  Future<void> rate(String videoId, String rating) async {
    await _postJson('/ratings', <String, dynamic>{
      'videoId': videoId,
      'rating': rating,
    });
  }

  Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    throw const YtmRequestException('Unexpected response shape.');
  }

  List<dynamic> _asList(dynamic value) {
    if (value is List<dynamic>) return value;
    throw const YtmRequestException('Unexpected response shape.');
  }

  void dispose() => _client.close();
}
