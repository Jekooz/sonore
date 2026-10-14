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

  /// POST /auth/browser/start — the project's established sign-in hand-off:
  /// the sidecar opens music.youtube.com and waits for the companion
  /// extension, with the pairing token written to the extension folder.
  Future<String> startBrowserSignIn() => _api.startBrowserSignIn();

  /// GET /auth/browser/status -> idle | waiting | done | failed | cancelled
  Future<String> browserSignInState() => _api.browserSignInState();

  /// POST /auth/signout — the sidecar forgets the stored session. The app
  /// itself never holds one, so there is nothing else to clear.
  Future<void> signOut() => _api.signOut();

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

/// Home's rails.
final FutureProvider<List<HomeRow>> homeProvider =
    FutureProvider<List<HomeRow>>(
  (ref) => ref.watch(ytmRepositoryProvider).home(),
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
class SignInController extends Notifier<SignInState> {
  Timer? _poll;

  @override
  SignInState build() {
    ref.onDispose(() => _poll?.cancel());
    return const SignInState();
  }

  /// Starts the browser hand-off and polls the sidecar until it finishes.
  Future<void> start() async {
    if (state.isWaiting) return;
    try {
      final String initial = await ref
          .read(ytmRepositoryProvider)
          .startBrowserSignIn();
      state = SignInState(stage: SignInStage.waiting, detail: initial);
    } on YtmException catch (error) {
      state = SignInState(stage: SignInStage.failed, detail: error.message);
      return;
    }

    _poll?.cancel();
    // The sidecar's own timeout for the hand-off is three minutes; poll a
    // little longer so its final state is observed rather than guessed.
    _poll = Timer.periodic(const Duration(seconds: 2), (Timer timer) async {
      if (!ref.mounted) {
        timer.cancel();
        return;
      }
      final String status;
      try {
        status = await ref.read(ytmRepositoryProvider).browserSignInState();
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
      switch (status) {
        case 'done':
          timer.cancel();
          state = const SignInState(stage: SignInStage.done);
          ref.invalidate(connectionProvider);
        case 'failed':
          timer.cancel();
          state = const SignInState(
            stage: SignInStage.failed,
            detail: 'Sign-in was not completed.',
          );
        case 'cancelled':
          timer.cancel();
          state = const SignInState();
        default:
          state = SignInState(stage: SignInStage.waiting, detail: status);
      }
    });
  }

  void cancel() {
    _poll?.cancel();
    state = const SignInState();
  }
}

enum SignInStage { idle, waiting, done, failed }

@immutable
class SignInState {
  const SignInState({this.stage = SignInStage.idle, this.detail});

  final SignInStage stage;
  final String? detail;

  bool get isWaiting => stage == SignInStage.waiting;
}

final NotifierProvider<SignInController, SignInState> signInProvider =
    NotifierProvider<SignInController, SignInState>(SignInController.new);
