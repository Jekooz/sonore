import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/track.dart';

class ApiException implements Exception {
  ApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// HTTP client for the existing FastAPI sidecar (`backend/main.py`).
///
/// Credential rule (project non-negotiable + design.md section 3.I): this client
/// never receives, stores, or logs cookies, session values or signed stream
/// URLs. The sidecar owns the session (keyring / Windows Credential Locker);
/// the POC only asks it for state, search rows and a playable URL.
class ApiClient {
  ApiClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// Override for the emulator/host case: --dart-define=YTM_BASE_URL=http://10.0.2.2:8003
  static const String _override = String.fromEnvironment('YTM_BASE_URL');

  String? _baseUrl;

  bool get isConnected => _baseUrl != null;
  String get baseUrl => _baseUrl ?? '(not connected)';

  /// The sidecar picks a free port at boot (8000-8099) and publishes it to
  /// %TEMP%/ytmusic_sidecar_port.txt — the same contract the WinUI client's
  /// SidecarLauncher uses. Android has no sidecar on-device, so the host
  /// loopback address is tried there instead.
  Future<String?> connect({Duration timeout = const Duration(seconds: 3)}) async {
    for (final candidate in await _candidates()) {
      try {
        final res = await _client.get(Uri.parse('$candidate/health')).timeout(timeout);
        if (res.statusCode == 200 && res.body.contains('"ok"')) {
          _baseUrl = candidate;
          return candidate;
        }
      } catch (_) {
        // Not this one; try the next candidate.
      }
    }
    return null;
  }

  Future<List<String>> _candidates() async {
    final list = <String>[];
    if (_override.isNotEmpty) list.add(_override);
    try {
      final file = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}ytmusic_sidecar_port.txt',
      );
      if (await file.exists()) {
        final port = (await file.readAsString()).trim();
        if (int.tryParse(port) != null) list.add('http://127.0.0.1:$port');
      }
    } catch (_) {
      // Unreadable temp dir is not fatal.
    }
    if (Platform.isAndroid) list.add('http://10.0.2.2:8000');
    list.add('http://127.0.0.1:8000');
    return list;
  }

  Uri _u(String path, [Map<String, String>? query]) =>
      Uri.parse('$_baseUrl$path').replace(queryParameters: query);

  /// GET /health
  Future<bool> health() async {
    final res = await _client.get(_u('/health'));
    return res.statusCode == 200;
  }

  /// GET /auth/status -> {"logged_in": bool, "error": str|null}
  Future<bool> isSignedIn() async {
    final res = await _client.get(_u('/auth/status'));
    if (res.statusCode != 200) return false;
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return body['logged_in'] == true;
  }

  /// GET /auth/browser/info -> {"browser": name}
  Future<String> defaultBrowser() async {
    final res = await _client.get(_u('/auth/browser/info'));
    if (res.statusCode != 200) return 'your browser';
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return (body['browser'] as String?) ?? 'your browser';
  }

  /// POST /auth/browser/start — opens music.youtube.com in the default browser
  /// and starts the extension hand-off (2 s poll, 3 min timeout, server side).
  /// Returns the session state only; no cookie material ever crosses the wire.
  Future<String> startBrowserSignIn() async {
    final res = await _client.post(_u('/auth/browser/start'));
    if (res.statusCode != 200) throw ApiException('sign-in start failed (${res.statusCode})');
    return _stateOf(res.body);
  }

  /// GET /auth/browser/status -> {"state": idle|waiting|..., "browser":.., "error":..}
  Future<String> browserSignInState() async {
    final res = await _client.get(_u('/auth/browser/status'));
    if (res.statusCode != 200) throw ApiException('sign-in status failed (${res.statusCode})');
    return _stateOf(res.body);
  }

  String _stateOf(String body) {
    final json = jsonDecode(body) as Map<String, dynamic>;
    return (json['state'] as String?) ?? 'unknown';
  }

  /// GET /search?q=&filter= — real ytmusicapi search; each row is a result.
  Future<List<Track>> search(String query, {String? filter}) async {
    final res = await _client.get(_u('/search', {
      'q': query,
      if (filter != null && filter.isNotEmpty) 'filter': filter,
    }));
    if (res.statusCode != 200) throw ApiException('search failed (${res.statusCode})');
    final rows = jsonDecode(res.body) as List<dynamic>;
    return rows
        .map((row) => Track.fromSearchResult(row as Map<String, dynamic>))
        .whereType<Track>()
        .toList(growable: false);
  }

  /// GET /stream/{video_id} -> {"videoId":..., "url":...}. The URL is short-lived
  /// and is deliberately never logged.
  Future<String> streamUrl(String videoId) async {
    final res = await _client.get(_u('/stream/$videoId'));
    if (res.statusCode != 200) throw ApiException('stream resolve failed (${res.statusCode})');
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final url = body['url'] as String?;
    if (url == null || url.isEmpty) throw ApiException('no stream url for $videoId');
    return url;
  }

  void dispose() => _client.close();
}
