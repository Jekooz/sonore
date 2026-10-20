import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/listening_event.dart';
import '../audio/track.dart';
import 'api_client.dart';
import 'models.dart';

/// The sidecar client. Overridden in tests with `MockClient`-backed instances so
/// the real client and the real parsers run against recorded service payloads.
final Provider<YtmApiClient> apiClientProvider = Provider<YtmApiClient>((ref) {
  final YtmApiClient client = YtmApiClient();
  ref.onDispose(client.dispose);
  return client;
});

/// What the app knows about its own connection, which is what lets a screen say
/// "offline" rather than showing a generic failure.
enum YtmStatus {
  /// The sidecar answers and has a usable session.
  ready,

  /// The sidecar answers but nobody is signed in.
  signedOut,

  /// The sidecar is not running or not reachable.
  offline,
}

@immutable
class YtmConnection {
  const YtmConnection({
    required this.status,
    this.accountName,
    this.handle,
    this.photoUrl,
  });

  final YtmStatus status;
  final String? accountName;
  final String? handle;
  final String? photoUrl;

  bool get isReady => status == YtmStatus.ready;
}

/// Reads the account header the app shows once a session exists.
@immutable
class YtmAccount {
  const YtmAccount({
    required this.name,
    this.handle = '',
    this.photoUrl,
  });

  final String name;
  final String handle;
  final String? photoUrl;
}

/// The playback engine (yt-dlp) the sidecar uses to resolve stream URLs, plus
/// the result of the last update check. Settings → Playback renders this.
///
/// Named `...Info` on purpose: the audio layer already owns `PlaybackEngine`
/// (the just_audio wrapper in `lib/audio/playback_engine.dart`), and the two
/// must not be confused.
@immutable
class PlaybackEngineInfo {
  const PlaybackEngineInfo({
    this.version,
    this.source = 'bundled',
    this.lastOk,
    this.lastError,
    this.lastCheck,
  });

  /// The upstream yt-dlp version, or null when it could not be read.
  final String? version;

  /// Where the binary came from: `bundled`, `path`, or `updated`.
  final String source;

  /// Result of the last update check: true (ok), false (failed), or null
  /// (never checked).
  final bool? lastOk;

  /// The failure message from the last check, if any.
  final String? lastError;

  /// ISO-8601 timestamp of the last check, if any.
  final String? lastCheck;
}

/// Maps the sidecar's endpoints onto the app's models.
///
/// Every method here can throw [YtmOfflineException], [YtmSignedOutException]
/// or [YtmRequestException]; the screens turn those into the loading / empty /
/// error / offline / sign-in states the spec asks for.
class YtmRepository {
  YtmRepository(this._api);

  final YtmApiClient _api;

  /// Health, then session state. Never throws: an unreachable sidecar or a
  /// signed-out answer is a *state*, not an error the user has to dismiss, so a
  /// screen can always say which of the two it is looking at.
  Future<YtmConnection> connection() async {
    try {
      if (!await _api.health()) {
        return const YtmConnection(status: YtmStatus.offline);
      }
    } on YtmException {
      return const YtmConnection(status: YtmStatus.offline);
    }

    final bool signedIn;
    try {
      signedIn = await _api.isSignedIn();
    } on YtmException {
      // The sidecar answered /health but not /auth/status: treat it as offline
      // rather than as a session problem.
      return const YtmConnection(status: YtmStatus.offline);
    }
    if (!signedIn) return const YtmConnection(status: YtmStatus.signedOut);

    try {
      final Map<String, dynamic> account = await _api.account();
      return YtmConnection(
        status: YtmStatus.ready,
        accountName: account['accountName'] as String?,
        handle: account['channelHandle'] as String?,
        photoUrl: account['accountPhotoUrl'] as String?,
      );
    } on YtmSignedOutException {
      // The sidecar cleared the stored session while answering (expired or
      // rejected): that is a signed-out state, not a flaky upstream, and
      // "Signed in as" must not keep showing the old account.
      return const YtmConnection(status: YtmStatus.signedOut);
    } on YtmException {
      // /account can fail while /auth/status still says signed in (a flaky
      // upstream). The session is usable either way, so this must not turn the
      // whole app into an error.
      return const YtmConnection(status: YtmStatus.ready);
    }
  }

  /// GET /home — real personalized rows, with empty rails dropped.
  Future<List<HomeRow>> home() async {
    final List<dynamic> rows = await _api.home();
    final List<HomeRow> result = <HomeRow>[];
    for (final dynamic row in rows) {
      if (row is! Map<String, dynamic>) continue;
      final String title = (row['title'] as String? ?? '').trim();
      final List<MediaItem> items = _items(row['contents']);
      if (title.isEmpty || items.isEmpty) continue;
      result.add(HomeRow(title: title, items: items));
    }
    return result;
  }

  /// GET /library/{segment}
  ///
  /// History is the one segment whose payload is the app's own record rather
  /// than a list of service rows, so it reads through its own endpoint and is
  /// assembled into the same row shape the list renders.
  Future<List<MediaItem>> library(LibrarySegment segment) async {
    if (segment == LibrarySegment.history) return history();
    return _items(await _api.library(segment.endpoint));
  }

  /// GET /library/subscriptions — the channel ids the account follows.
  ///
  /// Returned as [artistChannelKey]s so the Home hero's Follow button can
  /// compare a featured release's artist against it without caring which of the
  /// service's two artist id forms each side happened to use.
  Future<Set<String>> subscribedArtistIds() async {
    final List<dynamic> rows = await _api.subscriptions();
    final Set<String> ids = <String>{};
    for (final dynamic row in rows) {
      if (row is! Map<String, dynamic>) continue;
      final String id = ((row['browseId'] as String?) ??
              (row['channelId'] as String?) ??
              '')
          .trim();
      if (id.isEmpty) continue;
      ids.add(artistChannelKey(id));
    }
    return ids;
  }

  /// POST /library/subscriptions — follow or unfollow an artist.
  ///
  /// A real capability: the sidecar forwards it to ytmusicapi, so the change
  /// lands on the user's account rather than only in this session.
  Future<void> setArtistSubscribed(String artistId, bool subscribed) =>
      _api.setArtistSubscribed(artistId, subscribed);

  /// GET /listening/history — what this app played, newest first.
  ///
  /// A row is only built when the stored event carried a title, because a row
  /// with no name cannot be played or recognised. Album artwork is not stored
  /// locally, so these rows show the designed no-artwork placeholder rather
  /// than a made-up image.
  Future<List<MediaItem>> history({int limit = 30}) async {
    final List<dynamic> entries = await _api.listeningHistory(limit: limit);
    final List<MediaItem> items = <MediaItem>[];
    for (final dynamic entry in entries) {
      if (entry is! Map<String, dynamic>) continue;
      final String id = (entry['videoId'] as String? ?? '').trim();
      final String title = (entry['title'] as String? ?? '').trim();
      final String artist = (entry['artist'] as String? ?? '').trim();
      if (id.isEmpty || title.isEmpty) continue;
      final MediaItem? item = mediaItemFrom(<String, dynamic>{
        'videoId': id,
        'title': title,
        if (artist.isNotEmpty)
          'artists': <Map<String, String>>[<String, String>{'name': artist}],
      });
      if (item != null) items.add(item);
    }
    return items;
  }

  /// GET /search — grouped the way the spec asks for.
  Future<SearchResults> search(String query) async {
    final List<dynamic> rows = await _api.search(query);

    final List<MediaItem> songs = <MediaItem>[];
    final List<MediaItem> albums = <MediaItem>[];
    final List<MediaItem> artists = <MediaItem>[];
    final List<MediaItem> playlists = <MediaItem>[];

    for (final dynamic row in rows) {
      if (row is! Map<String, dynamic>) continue;
      final MediaItem? item = mediaItemFrom(row);
      if (item == null) continue;
      switch (item.kind) {
        // Videos and podcast episodes are playable audio the service returned
        // for the query; they belong with the tracks, labelled as such.
        case MediaKind.song:
        case MediaKind.video:
        case MediaKind.episode:
          songs.add(item);
        case MediaKind.album:
          albums.add(item);
        case MediaKind.artist:
          artists.add(item);
        case MediaKind.playlist:
          playlists.add(item);
      }
    }

    return SearchResults(
      songs: songs,
      albums: albums,
      artists: artists,
      playlists: playlists,
      query: query,
    );
  }

  /// GET /album/{browseId}, /playlist/{id} or /artist/{id} — one payload shape.
  Future<Collection> collection(CollectionRef ref) async {
    final Map<String, dynamic> json = switch (ref.kind) {
      CollectionKind.album => await _api.album(ref.id),
      CollectionKind.playlist => await _api.playlist(ref.id),
      CollectionKind.artist => await _api.artist(ref.id),
    };

    return Collection(
      ref: ref,
      title: (json['title'] as String? ?? '').trim(),
      subtitle: (json['subtitle'] as String? ?? '').trim(),
      artworkUrl: largestThumbnail(json),
      tracks: _items(json['tracks']),
    );
  }

  /// Streams are resolved by the audio layer through this, never by a widget.
  Future<String> streamUrl(Track track) => _api.streamUrl(track.id);

  Future<void> prefetch(Track track) => _api.prefetch(track.id);

  /// GET /recommendations — real ranked candidates for Autoplay, with the
  /// current queue excluded.
  ///
  /// Rows that are not playable are dropped rather than queued: the ranking
  /// service is allowed to hand back a playlist or an artist card, and a queue
  /// cannot play one.
  Future<List<Track>> recommendations(
    Track seed, {
    int limit = 12,
    List<String> exclude = const <String>[],
  }) async {
    final List<MediaItem> items = _items(
      await _api.recommendations(seed.id, limit: limit, exclude: exclude),
    );
    return items
        .map((MediaItem item) => item.track)
        .whereType<Track>()
        .toList(growable: false);
  }

  /// POST /listening/events — what was played and how it ended.
  Future<void> reportListeningEvent(ListeningEvent event) =>
      _api.reportListeningEvent(event.toJson());

  /// GET /lyrics/{videoId} — real lyrics for the current track.
  ///
  /// Returns null when YouTube Music has none, which is a normal answer the
  /// screen renders as "no lyrics", not as an error.
  Future<LyricsResult?> lyrics(Track track) async {
    final Map<String, dynamic>? body = await _api.lyrics(track.id);
    if (body == null) return null;
    final LyricsResult result = LyricsResult.fromJson(body);
    return result.isEmpty ? null : result;
  }

  Future<void> setLike(String videoId, bool liked) =>
      _api.rate(videoId, liked ? 'LIKE' : 'INDIFFERENT');

  /// POST /auth/browser/start — begins a sign-in. The sidecar owns the whole
  /// flow: it signs in from an already signed-in profile with no window at all,
  /// or opens the browser the user set as default in Windows — their own
  /// Firefox profile, or a Chromium in a profile it owns — for them to sign in
  /// there. Nothing is installed and no extension is involved.
  ///
  /// [openBrowser] is false when the caller only needs an attempt to hand
  /// cookies to, which is what the paste-headers fallback does.
  Future<SignInAttempt> startBrowserSignIn({bool openBrowser = true}) async {
    final Map<String, dynamic> body =
        await _api.startBrowserSignIn(openBrowser: openBrowser);
    return SignInAttempt(
      state: (body['state'] as String?) ?? 'unknown',
      browser: body['browser'] as String?,
      error: body['error'] as String?,
    );
  }

  /// GET /auth/browser/status — the attempt's state, the browser sign-in is
  /// using, and the sidecar's own reason when the attempt failed.
  ///
  /// [browser] is what the waiting screen names, so the user knows which window
  /// to look for — this app can open one that is not their usual browser, and
  /// saying so is cheaper than them guessing.
  Future<BrowserSignInStatus> browserSignInStatus() async {
    final Map<String, dynamic> body = await _api.browserSignInStatus();
    return BrowserSignInStatus(
      state: (body['state'] as String?) ?? 'unknown',
      browser: body['browser'] as String?,
      error: body['error'] as String?,
    );
  }

  /// POST /auth/browser/cancel - retires the attempt server-side too, so it
  /// cannot outlive the screen that started it.
  Future<void> cancelBrowserSignIn() => _api.cancelBrowserSignIn();

  /// POST /auth/browser/finish - "I've signed in". The sidecar closes the
  /// sign-in window, which is what makes its profile readable, and then reports
  /// the result through the same status the screen already polls.
  Future<void> finishBrowserSignIn() => _api.finishBrowserSignIn();

  /// POST /auth/handoff with pasted request headers — the fallback for a
  /// machine where the app cannot drive a browser of its own.
  ///
  /// Starts an attempt without opening a browser, then feeds the pasted
  /// headers to the loopback endpoint; the sidecar recovers the cookie line,
  /// validates the candidate against YouTube and stores it encrypted.
  Future<void> signInWithPastedHeaders(String rawHeaders) async {
    final Map<String, String> headers = parseRequestHeaders(rawHeaders);
    if (headers['cookie'] == null || headers['cookie']!.isEmpty) {
      throw const YtmSignedOutException(
        "The pasted headers don't include a 'cookie:' line. Copy the full "
        'request headers from your signed-in music.youtube.com tab.',
      );
    }

    await startBrowserSignIn(openBrowser: false);
    try {
      await _api.handoff(headers: headers);
    } finally {
      // Retire the attempt either way: a failed paste must not leave one
      // waiting, and a successful one has already been consumed.
      try {
        await _api.cancelBrowserSignIn();
      } on YtmException {
        // The sidecar times an abandoned attempt out on its own.
      }
    }
  }

  /// POST /auth/signout — the sidecar forgets the stored session. The app
  /// itself never holds one, so there is nothing else to clear.
  Future<void> signOut() => _api.signOut();

  /// The per-install API token, for callers that need it directly. The app
  /// sends it automatically on every locked request, so nothing in the UI has
  /// to show or copy it.
  Future<String?> installToken() => _api.installToken();

  /// The playback engine (yt-dlp) in use: version, source and last update.
  Future<PlaybackEngineInfo> playbackEngineInfo() async {
    final Map<String, dynamic> body = await _api.playbackEngine();
    final dynamic update = body['update'];
    return PlaybackEngineInfo(
      version: body['version'] as String?,
      source: body['source'] as String? ?? 'bundled',
      lastOk: update is Map<String, dynamic> ? update['ok'] as bool? : null,
      lastError: update is Map<String, dynamic> ? update['error'] as String? : null,
      lastCheck: update is Map<String, dynamic>
          ? update['last_check'] as String?
          : null,
    );
  }

  /// POST /playback/engine/update — ask the sidecar to refresh yt-dlp. It runs
  /// in the background; callers re-read [playbackEngine] to see the result.
  Future<void> updatePlaybackEngine() => _api.updatePlaybackEngine();

  List<MediaItem> _items(dynamic raw) {
    if (raw is! List<dynamic>) return const <MediaItem>[];
    final List<MediaItem> items = <MediaItem>[];
    for (final dynamic entry in raw) {
      if (entry is! Map<String, dynamic>) continue;
      final MediaItem? item = mediaItemFrom(entry);
      if (item != null) items.add(item);
    }
    return items;
  }
}

final Provider<YtmRepository> ytmRepositoryProvider = Provider<YtmRepository>(
  (ref) => YtmRepository(ref.watch(apiClientProvider)),
);

/// Connection + session state. `keepAlive` because every screen depends on it
/// and re-probing the sidecar on each navigation would be needless traffic.
final FutureProvider<YtmConnection> connectionProvider =
    FutureProvider<YtmConnection>(
  (ref) => ref.watch(ytmRepositoryProvider).connection(),
);

/// The playback engine (yt-dlp) state, for Settings → Playback. The update is
/// a background job on the sidecar, so the screen refreshes this provider to
/// pick up the new version and result.
final FutureProvider<PlaybackEngineInfo> playbackEngineInfoProvider =
    FutureProvider<PlaybackEngineInfo>(
  (ref) => ref.watch(ytmRepositoryProvider).playbackEngineInfo(),
);

/// Home's rails.
final FutureProvider<List<HomeRow>> homeProvider =
    FutureProvider<List<HomeRow>>(
  (ref) => ref.watch(ytmRepositoryProvider).home(),
);

/// The artists the account follows, as [artistChannelKey]s.
///
/// The Home hero reads this so its Follow button shows the real state instead
/// of guessing; a sidecar that cannot answer leaves it null, which the button
/// treats as "not following yet".
final FutureProvider<Set<String>> subscribedArtistsProvider =
    FutureProvider<Set<String>>(
  (ref) => ref.watch(ytmRepositoryProvider).subscribedArtistIds(),
);

/// One library segment. Family types are not exported by flutter_riverpod, so
/// these are inferred rather than annotated.
final libraryProvider = FutureProvider.family<List<MediaItem>, LibrarySegment>(
  (ref, LibrarySegment segment) =>
      ref.watch(ytmRepositoryProvider).library(segment),
);

/// One album / playlist / artist page.
final collectionProvider = FutureProvider.family<Collection, CollectionRef>(
  (ref, CollectionRef target) =>
      ref.watch(ytmRepositoryProvider).collection(target),
);

/// The signed-out state's one real action.
///
/// The failure this replaces: the sidecar reports "success" when the
/// hand-off lands, but this controller only switched on "done" — so a
/// successful sign-in fell through to the default branch, the screen spun
/// on "waiting" forever, and the waiting guard made every retry a no-op.
class SignInController extends Notifier<SignInState> {
  Timer? _poll;

  @override
  SignInState build() {
    ref.onDispose(() => _poll?.cancel());
    return const SignInState();
  }

  /// Starts the sign-in and polls the sidecar until it finishes.
  ///
  /// The sidecar owns the whole browser flow — it signs in from an existing
  /// Firefox session with no window at all, or opens a window of its own for
  /// the user to sign in — so the app opens nothing itself and exactly one
  /// window appears.
  Future<void> start() async {
    if (state.isWaiting) return;
    _poll?.cancel();

    final SignInAttempt attempt;
    try {
      attempt = await ref.read(ytmRepositoryProvider).startBrowserSignIn();
    } on YtmException catch (error) {
      state = SignInState(stage: SignInStage.failed, detail: error.message);
      return;
    }
    if (attempt.state == 'failed') {
      state = SignInState(
        stage: SignInStage.failed,
        detail: attempt.error ?? _signInNotCompleted,
      );
      return;
    }
    state = SignInState(
      stage: SignInStage.waiting,
      detail: attempt.state,
      browser: attempt.browser,
    );

    // The sidecar times the attempt out at three minutes; wait a little
    // longer so its final state — with its own wording — is observed rather
    // than raced. The tick budget below is the app's own backstop for a
    // sidecar that stopped answering without going offline, counted in polls
    // rather than wall-clock time so the behaviour is deterministic under a
    // test clock.
    int elapsedPolls = 0;
    _poll = Timer.periodic(const Duration(seconds: 2), (Timer timer) async {
      if (!ref.mounted) {
        timer.cancel();
        return;
      }
      if (++elapsedPolls > _signInWaitPollTicks) {
        timer.cancel();
        await _abandon(
          'Sign-in timed out waiting for the browser window.',
        );
        return;
      }

      final BrowserSignInStatus status;
      try {
        status = await ref.read(ytmRepositoryProvider).browserSignInStatus();
      } on YtmException catch (error) {
        timer.cancel();
        state = SignInState(
          stage: SignInStage.failed,
          detail: error.message,
        );
        return;
      }
      if (!ref.mounted) {
        timer.cancel();
        return;
      }
      switch (status.state) {
        // "success" is what the sidecar actually reports on a completed
        // hand-off; "done" is kept so an older sidecar still completes.
        case 'success' || 'done':
          timer.cancel();
          state = const SignInState(stage: SignInStage.done);
          ref.invalidate(connectionProvider);
        case 'failed' || 'timeout':
          timer.cancel();
          // The sidecar's wording, not a generic one: it knows whether the
          // browser would not start, whether YouTube refused the session, or
          // whether nobody signed in in time, and each of those needs a
          // different thing from the user.
          state = SignInState(
            stage: SignInStage.failed,
            detail: status.error ?? _signInNotCompleted,
          );
        case 'cancelled' || 'idle':
          timer.cancel();
          state = const SignInState();
        default:
          state = SignInState(
            stage: SignInStage.waiting,
            detail: status.state,
            browser: status.browser ?? state.browser,
          );
      }
    });
  }

  /// Cancel: reset the screen AND retire the attempt on the sidecar, so it
  /// does not outlive this screen.
  Future<void> cancel() async {
    _poll?.cancel();
    state = const SignInState();
    try {
      await ref.read(ytmRepositoryProvider).cancelBrowserSignIn();
    } on YtmException {
      // A sidecar that cannot be reached times its own attempt out.
    }
  }

  /// "I've signed in": ask the sidecar to close the sign-in window and read the
  /// session out of it now, instead of waiting for the user to close it.
  ///
  /// Polling deliberately continues — the read is what completes the attempt,
  /// and its result (success, or a refusal with its own reason) arrives through
  /// the same status the screen already watches.
  Future<void> finish() async {
    if (!state.isWaiting) return;
    try {
      await ref.read(ytmRepositoryProvider).finishBrowserSignIn();
    } on YtmException {
      // The poll loop reports whatever the sidecar makes of the attempt.
    }
  }

  /// The app's own timeout fired: retire the attempt, then say so.
  Future<void> _abandon(String message) async {
    try {
      await ref.read(ytmRepositoryProvider).cancelBrowserSignIn();
    } on YtmException {
      // Best effort; the state below is what the user acts on.
    }
    state = SignInState(stage: SignInStage.failed, detail: message);
  }
}

/// How many 2-second polls the app keeps waiting for the hand-off before
/// giving up itself: 105 ticks = 3 min 30 s, a little beyond the sidecar's
/// own three-minute timeout.
const int _signInWaitPollTicks = 105;

/// What GET /auth/browser/start answered: the attempt's state, the browser it
/// is using, and any error text.
@immutable
class SignInAttempt {
  const SignInAttempt({required this.state, this.browser, this.error});

  final String state;
  final String? browser;
  final String? error;
}

/// What GET /auth/browser/status answered: the attempt's state, the browser it
/// is using, and — when it failed — the sidecar's explanation of why.
@immutable
class BrowserSignInStatus {
  const BrowserSignInStatus({required this.state, this.browser, this.error});

  final String state;
  final String? browser;
  final String? error;
}

/// Parses a pasted block of raw request headers ("Name: value" lines, as
/// copied from a browser's devtools) into a lowercase name -> value map.
///
/// Blank lines and a leading request line ("GET /... HTTP/1.1") are skipped,
/// and any line without a colon is ignored rather than throwing: this field
/// is typed by hand and must degrade to "no cookie line" instead of a crash.
Map<String, String> parseRequestHeaders(String raw) {
  final Map<String, String> headers = <String, String>{};
  for (final String line in raw.split(RegExp(r'\r?\n'))) {
    final int colon = line.indexOf(':');
    if (colon <= 0) continue;
    final String name = line.substring(0, colon).trim().toLowerCase();
    final String value = line.substring(colon + 1).trim();
    if (name.isNotEmpty) headers[name] = value;
  }
  return headers;
}

enum SignInStage { idle, waiting, done, failed }

/// Shown when the sidecar fails an attempt without saying why. It normally
/// supplies its own wording; this is only a floor, so a failure is never blank.
const String _signInNotCompleted = 'Sign-in was not completed.';

@immutable
class SignInState {
  const SignInState({this.stage = SignInStage.idle, this.detail, this.browser});

  final SignInStage stage;
  final String? detail;

  /// The browser the sidecar said it is using, for the waiting copy.
  final String? browser;

  bool get isWaiting => stage == SignInStage.waiting;
}

final NotifierProvider<SignInController, SignInState> signInProvider =
    NotifierProvider<SignInController, SignInState>(SignInController.new);
