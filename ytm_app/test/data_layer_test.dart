import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ytm_app/audio/listening_event.dart';
import 'package:ytm_app/audio/track.dart';
import 'package:ytm_app/data/api_client.dart';
import 'package:ytm_app/data/models.dart';
import 'package:ytm_app/data/ytm_repository.dart';

import 'support/recorded_sidecar.dart';

/// A track used only to exercise the stream endpoint.
const Track _probeTrack = Track(id: 'abc', title: 'Probe', artist: 'Nobody');

YtmRepository repositoryOver(http.Client client) => YtmRepository(
      YtmApiClient(client: client, readPortFile: () async => '8000'),
    );

void main() {
  group('connection state', () {
    test('a healthy sidecar with a session is ready', () async {
      final YtmConnection connection =
          await repositoryOver(recordedSidecar()).connection();

      expect(connection.status, YtmStatus.ready);
      expect(connection.accountName, 'Test Account');
      expect(connection.handle, '@test_account');
    });

    test('an unreachable sidecar is offline, not an error', () async {
      final MockClient dead = MockClient(
        (http.Request request) async => throw const SocketException('refused'),
      );

      expect(
        (await repositoryOver(dead).connection()).status,
        YtmStatus.offline,
      );
    });

    test('a sidecar without a session reports signed out', () async {
      final YtmRepository repo = repositoryOver(
        recordedSidecar(responses: <String, http.Response>{
          '/auth/status': jsonOk('{"logged_in":false,"error":null}'),
        }),
      );

      expect((await repo.connection()).status, YtmStatus.signedOut);
    });

    test('/account failing does not turn a usable session into an error',
        () async {
      final YtmRepository repo = repositoryOver(
        recordedSidecar(responses: <String, http.Response>{
          '/account': http.Response('{"detail":"upstream hiccup"}', 502),
        }),
      );

      expect((await repo.connection()).status, YtmStatus.ready);
    });
  });

  group('home', () {
    test('rails parse into titled rows of cards', () async {
      final List<HomeRow> rows = await repositoryOver(recordedSidecar()).home();

      expect(rows, isNotEmpty);
      expect(rows.first.title, isNotEmpty);
      expect(rows.first.items, isNotEmpty);
      // The recording holds three rails, each with cards.
      expect(rows, hasLength(3));
      for (final HomeRow row in rows) {
        expect(row.items, isNotEmpty, reason: row.title);
      }
    });

    test('every card resolves to something it can actually do', () async {
      final List<HomeRow> rows = await repositoryOver(recordedSidecar()).home();

      for (final HomeRow row in rows) {
        for (final MediaItem item in row.items) {
          expect(
            item.isPlayable || item.collection != null,
            isTrue,
            reason: '"${item.title}" has neither a track nor a collection',
          );
          expect(item.title, isNotEmpty);
        }
      }
    });

    test('the real home mix contains playable songs and collections', () async {
      final List<HomeRow> rows = await repositoryOver(recordedSidecar()).home();
      final List<MediaItem> all =
          rows.expand((HomeRow row) => row.items).toList();

      final List<MediaItem> playable =
          all.where((MediaItem item) => item.isPlayable).toList();
      expect(playable, isNotEmpty);
      for (final MediaItem item in playable) {
        expect(item.track!.id, isNotEmpty);
        expect(item.track!.title, isNotEmpty);
        expect(item.track!.artist, isNotEmpty);
      }

      final List<MediaItem> collections =
          all.where((MediaItem item) => item.collection != null).toList();
      expect(collections, isNotEmpty);
      for (final MediaItem item in collections) {
        expect(
          item.collection!.kind,
          anyOf(
            CollectionKind.album,
            CollectionKind.playlist,
            CollectionKind.artist,
          ),
        );
      }
    });

    test('an album card routes by its browse id and names its performer',
        () async {
      final List<HomeRow> rows = await repositoryOver(recordedSidecar()).home();
      final MediaItem album = rows
          .expand((HomeRow row) => row.items)
          .firstWhere((MediaItem item) => item.kind == MediaKind.album);

      expect(album.collection!.kind, CollectionKind.album);
      expect(album.collection!.id, startsWith('MPREb'));
      expect(
        album.collection!.routePath,
        startsWith('/collection/album/MPREb'),
      );
      // e.g. "EP · Karan Aujla".
      expect(album.subtitle, contains('·'));
    });

    test('an empty rails payload is an empty list, not an error', () async {
      final YtmRepository repo = repositoryOver(
        recordedSidecar(responses: <String, http.Response>{
          '/home': jsonOk('[]'),
        }),
      );

      expect(await repo.home(), isEmpty);
    });
  });

  group('search', () {
    test('the fixture really contains every result type it is meant to',
        () async {
      // Guards the fixture: if the recorded payload ever loses a group, this
      // fails loudly instead of the grouping test passing vacuously.
      final List<dynamic> raw =
          jsonDecode(fixture('search.json')) as List<dynamic>;
      final Set<Object?> types = raw
          .whereType<Map<String, dynamic>>()
          .map((Map<String, dynamic> row) => row['resultType'])
          .toSet();

      expect(types, containsAll(<String>[
        'song',
        'album',
        'artist',
        'playlist',
        'video',
        'episode',
      ]));
    });

    test('results group into songs, albums, artists and playlists', () async {
      final SearchResults results =
          await repositoryOver(recordedSidecar()).search('thriller');

      expect(results.query, 'thriller');
      expect(results.songs, isNotEmpty);
      expect(results.albums, isNotEmpty);
      expect(results.artists, isNotEmpty);
      expect(results.playlists, isNotEmpty);
      expect(results.isEmpty, isFalse);
      expect(
        results.length,
        results.songs.length +
            results.albums.length +
            results.artists.length +
            results.playlists.length,
      );
    });

    test('videos and episodes are grouped with the playable results', () async {
      final SearchResults results =
          await repositoryOver(recordedSidecar()).search('thriller');

      final List<MediaItem> nonSongs = results.songs
          .where((MediaItem item) => item.kind != MediaKind.song)
          .toList();
      expect(nonSongs, isNotEmpty);
      for (final MediaItem item in nonSongs) {
        expect(item.isPlayable, isTrue);
        expect(item.subtitle, isNotEmpty, reason: 'a non-song keeps its type');
      }
    });

    test('durations come from the service and are never invented', () async {
      final List<dynamic> raw =
          jsonDecode(fixture('search.json')) as List<dynamic>;
      final SearchResults results =
          await repositoryOver(recordedSidecar()).search('thriller');

      // Pair each parsed track with the exact row the service sent, so the
      // assertion is about fidelity, not about a fixed expectation. The real
      // payload is mixed: top results carry a duration, rows from the related
      // sections do not, and episodes never do.
      final Map<String, Map<String, dynamic>> sent =
          <String, Map<String, dynamic>>{};
      for (final dynamic row in raw) {
        if (row is Map<String, dynamic> && row['videoId'] is String) {
          sent[row['videoId'] as String] = row;
        }
      }

      int timed = 0;
      for (final MediaItem item in results.songs) {
        final Map<String, dynamic> row = sent[item.track!.id]!;
        final num? seconds = row['duration_seconds'] as num?;
        if (seconds == null) {
          expect(
            item.track!.duration,
            isNull,
            reason: '${item.title} must not invent a duration',
          );
        } else {
          expect(item.track!.duration, Duration(seconds: seconds.toInt()));
          timed++;
        }
        expect(item.track!.artist, isNotEmpty, reason: item.title);
      }
      expect(timed, greaterThan(0), reason: 'the fixture has timed rows');
    });

    test('a podcast episode keeps its show name and admits an unknown length',
        () async {
      final SearchResults results =
          await repositoryOver(recordedSidecar()).search('thriller');
      final MediaItem episode = results.songs
          .firstWhere((MediaItem item) => item.kind == MediaKind.episode);

      // The service sends no duration for an episode, so the app must leave it
      // unknown (which is what disables seeking) rather than invent one.
      expect(episode.track!.duration, isNull);
      expect(episode.track!.artist, isNotEmpty);
      expect(episode.subtitle, contains('Episode'));
    });

    test('a playlist row strips the VL prefix from its browse id', () async {
      final SearchResults results =
          await repositoryOver(recordedSidecar()).search('thriller');
      final MediaItem playlist = results.playlists.first;

      expect(playlist.collection!.kind, CollectionKind.playlist);
      expect(playlist.collection!.id, isNot(startsWith('VL')));
      expect(
        playlist.collection!.routePath,
        startsWith('/collection/playlist/'),
      );
      // The recorded row really does use the VL-prefixed form.
      expect(
        fixture('search.json'),
        contains('"browseId": "VL'),
      );
    });

    test('a query with no results is empty rather than malformed', () async {
      final YtmRepository repo = repositoryOver(
        recordedSidecar(responses: <String, http.Response>{
          '/search': jsonOk('[]'),
        }),
      );
      final SearchResults results = await repo.search('zzzznothing');

      expect(results.isEmpty, isTrue);
      expect(results.query, 'zzzznothing');
    });
  });

  group('library', () {
    test('every segment parses into routable rows', () async {
      final YtmRepository repo = repositoryOver(recordedSidecar());

      for (final LibrarySegment segment in LibrarySegment.values) {
        final List<MediaItem> items = await repo.library(segment);
        // History is the app's own record: on a machine that has played nothing
        // it is legitimately empty, so only its row shape is checked. The
        // populated case has its own group below.
        if (segment == LibrarySegment.history) {
          expect(items, isEmpty, reason: 'nothing has been played here');
          continue;
        }
        expect(items, isNotEmpty, reason: '${segment.label} was empty');

        for (final MediaItem item in items) {
          expect(item.title, isNotEmpty, reason: '${segment.label} title');
          expect(
            item.isPlayable || item.collection != null,
            isTrue,
            reason: '${segment.label} row "${item.title}" cannot act',
          );
        }
      }
    });

    test('songs carry their artist, album and real like state', () async {
      final List<MediaItem> songs =
          await repositoryOver(recordedSidecar()).library(LibrarySegment.songs);

      final MediaItem first = songs.first;
      expect(first.isPlayable, isTrue);
      expect(first.track!.artist, isNotEmpty);
      expect(first.track!.album, isNotNull);
      expect(first.track!.duration, isNotNull);
      // Library songs are in the library, so the service marks them liked.
      expect(first.track!.isLiked, isTrue);
    });

    test('playlists, albums and artists route to their own pages', () async {
      final YtmRepository repo = repositoryOver(recordedSidecar());

      final MediaItem playlist =
          (await repo.library(LibrarySegment.playlists)).first;
      expect(playlist.collection!.kind, CollectionKind.playlist);

      final MediaItem album = (await repo.library(LibrarySegment.albums)).first;
      expect(album.collection!.kind, CollectionKind.album);
      expect(album.collection!.id, startsWith('MPREb'));

      final MediaItem artist =
          (await repo.library(LibrarySegment.artists)).first;
      expect(artist.collection!.kind, CollectionKind.artist);
      expect(artist.title, isNotEmpty);
      expect(artist.subtitle, isNotEmpty, reason: 'subscriber count');
    });

    test('the liked segment returns the liked songs the service reported',
        () async {
      final List<MediaItem> liked =
          await repositoryOver(recordedSidecar()).library(LibrarySegment.liked);

      expect(liked, isNotEmpty);
      expect(liked.every((MediaItem item) => item.isPlayable), isTrue);
    });

    test('an owned playlist names its owner and its track count', () async {
      final List<MediaItem> playlists =
          await repositoryOver(recordedSidecar())
              .library(LibrarySegment.playlists);
      final Map<String, dynamic> owned = (
              jsonDecode(fixture('library_playlists.json')) as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .firstWhere((Map<String, dynamic> row) =>
              ((row['author'] as String?) ?? '').isNotEmpty);

      final MediaItem parsed = playlists
          .firstWhere((MediaItem item) => item.title == owned['title']);

      expect(parsed.subtitle, '${owned['author']} · ${owned['count']} tracks');
    });

    test('a playlist with no owner and no count has an empty credit line',
        () async {
      // "Liked Music" is authored by nobody and the service states no count for
      // it; an empty line is the honest answer, not a made-up one.
      final List<MediaItem> playlists =
          await repositoryOver(recordedSidecar())
              .library(LibrarySegment.playlists);
      final MediaItem liked = playlists
          .firstWhere((MediaItem item) => item.collection?.id == 'LM');

      expect(liked.subtitle, isEmpty);
    });
  });

  group('collections', () {
    test('an album page brings back ordered, playable tracks', () async {
      final Collection collection = await repositoryOver(recordedSidecar())
          .collection(const CollectionRef(CollectionKind.album, 'MPREb_test'));

      expect(collection.title, isNotEmpty);
      expect(collection.subtitle, isNotEmpty);
      expect(collection.tracks, isNotEmpty);
      expect(collection.playableTracks, isNotEmpty);
      expect(
        collection.playableTracks.length,
        lessThanOrEqualTo(collection.tracks.length),
      );
      for (final MediaItem item in collection.tracks) {
        expect(item.isPlayable, isTrue);
        expect(item.track!.duration, isNotNull);
      }
    });

    test('a track keeps the album name the service reported', () async {
      final Collection collection = await repositoryOver(recordedSidecar())
          .collection(const CollectionRef(CollectionKind.album, 'MPREb_test'));

      final MediaItem first =
          collection.tracks.firstWhere((MediaItem i) => i.track!.album != null);
      expect(first.track!.album, isNotEmpty);
      // The album page names itself, so its tracks carry that name.
      expect(first.track!.album, collection.title);
    });

    test('a playlist page parses the same way', () async {
      final Collection collection = await repositoryOver(recordedSidecar())
          .collection(const CollectionRef(CollectionKind.playlist, 'LM'));

      expect(collection.ref.kind, CollectionKind.playlist);
      expect(collection.title, isNotEmpty);
      expect(collection.tracks, isNotEmpty);
      expect(collection.playableTracks, isNotEmpty);
    });

    test('an artist page brings back their playable songs', () async {
      final Collection collection = await repositoryOver(recordedSidecar())
          .collection(const CollectionRef(CollectionKind.artist, 'MPLAUC_test'));

      expect(collection.title, isNotEmpty);
      expect(collection.tracks, isNotEmpty);
      expect(collection.playableTracks, isNotEmpty);
    });

    test('an empty collection is empty, not an error', () async {
      final YtmRepository repo = repositoryOver(
        recordedSidecar(responses: <String, http.Response>{
          '/album/MPREb_empty': jsonOk(
            '{"kind":"album","title":"Nothing","subtitle":"","tracks":[]}',
          ),
        }),
      );

      final Collection collection = await repo
          .collection(const CollectionRef(CollectionKind.album, 'MPREb_empty'));

      expect(collection.tracks, isEmpty);
      expect(collection.playableTracks, isEmpty);
    });
  });

  group('recommendations (Autoplay)', () {
    /// The recorded sidecar plus a log of what the app actually asked for.
    MockClient recording(List<http.Request> log) => MockClient(
          (http.Request request) async {
            log.add(request);
            return recordedResponse(request);
          },
        );

    test('ranked candidates parse into playable tracks', () async {
      final List<Track> tracks = await repositoryOver(recordedSidecar())
          .recommendations(_probeTrack);

      expect(tracks, isNotEmpty);
      // The provider's ranked rows include ids, titles and artists: a row that
      // cannot be played must not reach the queue.
      expect(
        tracks.every((Track track) =>
            track.id.isNotEmpty && track.title.isNotEmpty),
        isTrue,
      );
    });

    test('the seed and the excluded queue are sent to the service', () async {
      final List<http.Request> log = <http.Request>[];
      await repositoryOver(recording(log)).recommendations(
        _probeTrack,
        limit: 5,
        exclude: const <String>['b', 'c'],
      );

      final Uri uri = log.last.url;
      expect(uri.path, '/recommendations');
      expect(uri.queryParameters['seed'], 'abc');
      expect(uri.queryParameters['limit'], '5');
      expect(uri.queryParameters['exclude'], 'b,c');
    });

    test('no exclusions means no exclude parameter at all', () async {
      final List<http.Request> log = <http.Request>[];
      await repositoryOver(recording(log)).recommendations(_probeTrack);

      expect(log.last.url.queryParameters.containsKey('exclude'), isFalse);
    });

    test('a signed-out sidecar surfaces as signed out, not as empty',
        () async {
      final YtmRepository repo = repositoryOver(
        recordedSidecar(responses: <String, http.Response>{
          '/recommendations':
              http.Response('{"detail":"Not signed in."}', 401),
        }),
      );

      expect(
        repo.recommendations(_probeTrack),
        throwsA(isA<YtmSignedOutException>()),
      );
    });

    test('an upstream failure keeps the sidecar\'s own words', () async {
      final YtmRepository repo = repositoryOver(
        recordedSidecar(responses: <String, http.Response>{
          '/recommendations': http.Response(
            '{"detail":"YouTube Music request failed: 500"}',
            502,
          ),
        }),
      );

      expect(
        repo.recommendations(_probeTrack),
        throwsA(
          isA<YtmRequestException>().having(
            (YtmRequestException e) => e.message,
            'message',
            contains('500'),
          ),
        ),
      );
    });
  });

  group('history (what this app played)', () {
    /// Two real entries in the store's own shape, as `GET /listening/history`
    /// returns them (the sidecar's `recent_plays`): newest first, one row per
    /// video, metadata from the newest event.
    const String entries = '''
{"entries":[
 {"videoId":"dQw4w9WgXcQ","title":"Played Later","artist":"Nova",
  "plays":2,"lastAt":1700000200,"lastOutcome":"skipped"},
 {"videoId":"jNQXAC9IVRw","title":"Played First","artist":"Kite Club",
  "plays":1,"lastAt":1700000100,"lastOutcome":"completed"}
],"count":2}
''';

    test('a played track becomes a playable row', () async {
      final List<MediaItem> items = await repositoryOver(
        recordedSidecar(responses: <String, http.Response>{
          '/listening/history': jsonOk(entries),
        }),
      ).history();

      expect(items, hasLength(2));
      expect(items.first.title, 'Played Later');
      expect(items.first.subtitle, 'Nova');
      expect(items.first.isPlayable, isTrue);
      // Nothing is invented for artwork the store never kept.
      expect(items.first.artworkUrl, isNull);
    });

    test('an entry with no recorded title is dropped, not shown blank',
        () async {
      final List<MediaItem> items = await repositoryOver(
        recordedSidecar(responses: <String, http.Response>{
          '/listening/history': jsonOk(
            '{"entries":[{"videoId":"dQw4w9WgXcQ","title":"","artist":"A"}],'
            '"count":1}',
          ),
        }),
      ).history();

      expect(items, isEmpty);
    });

    test('an empty store is an empty list, not an error', () async {
      expect(await repositoryOver(recordedSidecar()).history(), isEmpty);
    });

    test('a failing read is a request failure, not "nothing played"',
        () async {
      final YtmRepository repo = repositoryOver(
        recordedSidecar(responses: <String, http.Response>{
          '/listening/history':
              http.Response('{"detail":"history unavailable"}', 502),
        }),
      );

      expect(
        repo.history(),
        throwsA(isA<YtmRequestException>()),
      );
    });
  });

  group('listening events', () {
    test('the posted body is the sidecar\'s own shape', () async {
      final List<http.Request> log = <http.Request>[];
      final MockClient client = MockClient((http.Request request) async {
        log.add(request);
        return recordedResponse(request);
      });

      await repositoryOver(client).reportListeningEvent(
        const ListeningEvent(
          videoId: 'abc',
          outcome: ListeningOutcome.completed,
          title: 'Probe',
          artist: 'Nobody',
          listenedSeconds: 91.5,
          durationSeconds: 120,
        ),
      );

      final http.Request posted = log.last;
      expect(posted.method, 'POST');
      expect(posted.url.path, '/listening/events');
      expect(
        jsonDecode(posted.body),
        <String, dynamic>{
          'videoId': 'abc',
          'outcome': 'completed',
          'title': 'Probe',
          'artist': 'Nobody',
          'listenedSeconds': 91.5,
          'durationSeconds': 120,
        },
      );
    });
  });

  group('streams', () {
    test('a stream URL is returned for a track', () async {
      final String url =
          await repositoryOver(recordedSidecar()).streamUrl(_probeTrack);

      expect(url, 'https://stream.invalid/audio.m4a');
    });

    test('a missing url is a request failure, not an empty success', () async {
      final YtmRepository repo = repositoryOver(
        recordedSidecar(responses: <String, http.Response>{
          '/stream/abc': jsonOk('{"videoId":"abc","url":""}'),
        }),
      );

      await expectLater(
        repo.streamUrl(_probeTrack),
        throwsA(isA<YtmRequestException>()),
      );
    });
  });

  group('failures', () {
    test('401 means signed out, and carries the sidecar detail', () async {
      final YtmRepository repo = repositoryOver(
        recordedSidecar(responses: <String, http.Response>{
          '/home': http.Response('{"detail":"Sign in to continue."}', 401),
        }),
      );

      await expectLater(
        repo.home(),
        throwsA(
          isA<YtmSignedOutException>().having(
            (YtmSignedOutException e) => e.message,
            'message',
            'Sign in to continue.',
          ),
        ),
      );
    });

    test('502 is a retryable request failure carrying the sidecar detail',
        () async {
      final YtmRepository repo = repositoryOver(
        recordedSidecar(responses: <String, http.Response>{
          '/home': http.Response(
            '{"detail":"Could not resolve a stream for this track: boom"}',
            502,
          ),
        }),
      );

      await expectLater(
        repo.home(),
        throwsA(
          isA<YtmRequestException>()
              .having((YtmRequestException e) => e.statusCode, 'status', 502)
              .having(
                (YtmRequestException e) => e.message,
                'message',
                contains('Could not resolve a stream'),
              ),
        ),
      );
    });

    test('a connection failure is offline', () async {
      final MockClient client = MockClient(
        (http.Request request) async => throw const SocketException('refused'),
      );

      await expectLater(
        repositoryOver(client).home(),
        throwsA(isA<YtmOfflineException>()),
      );
    });

    test('a sidecar detail never leaks a URL into an error message', () async {
      final YtmRepository repo = repositoryOver(
        recordedSidecar(responses: <String, http.Response>{
          '/home': http.Response(
            '{"detail":"Failed on https://x.invalid/videoplayback?key=SECRET"}',
            502,
          ),
        }),
      );

      try {
        await repo.home();
        fail('expected a failure');
      } on YtmRequestException catch (error) {
        expect(error.message, isNot(contains('SECRET')));
        expect(error.message, isNot(contains('https://')));
        expect(error.message, contains('<url>'));
      }
    });
  });

  group('real payload shapes', () {
    test('a song card with a radio playlistId still counts as playable', () {
      // Home song cards carry both a videoId and an RDAM radio playlistId; the
      // radio id must not turn the card into a playlist link.
      final MediaItem? item = mediaItemFrom(<String, dynamic>{
        'title': 'Maria Maria (feat. The Product G&B)',
        'videoId': 'Y9XXeznskQ4',
        'playlistId': 'RDAMVMY9XXeznskQ4',
        'artists': <dynamic>[
          <String, dynamic>{'name': 'Santana', 'id': 'UCX0rR7x8'},
        ],
      });

      expect(item!.isPlayable, isTrue);
      expect(item.collection, isNull);
      expect(item.track!.artist, 'Santana');
    });

    test('an album string field and an album object both parse', () {
      final MediaItem? fromObject = mediaItemFrom(<String, dynamic>{
        'title': 'T',
        'videoId': 'v1',
        'artists': <dynamic>[],
        'album': <String, dynamic>{'name': 'BULLY', 'id': null},
      });
      final MediaItem? fromString = mediaItemFrom(<String, dynamic>{
        'title': 'T',
        'videoId': 'v2',
        'artists': <dynamic>[],
        'album': 'AUJLA SZN 1',
      });

      expect(fromObject!.track!.album, 'BULLY');
      expect(fromString!.track!.album, 'AUJLA SZN 1');
    });

    test('a row with no usable target is dropped, not rendered', () {
      expect(
        mediaItemFrom(<String, dynamic>{
          'title': 'Some podcast',
          'browseId': 'MPSPPL_GUID',
          'resultType': 'podcast',
        }),
        isNull,
      );
    });

    test('a credit field is read in every shape, never stringified', () {
      // The three shapes the real payloads use for the same field: a bare
      // string, one {name} object, and a list of objects (a Home rail playlist
      // card) — plus a list of bare strings.
      MediaItem? parse(dynamic owner) => mediaItemFrom(<String, dynamic>{
        'title': 'Owner shapes',
        'browseId': 'VLPL123',
        'author': ?owner,
      });

      expect(parse('Someone')!.subtitle, 'Someone');
      expect(parse(<String, dynamic>{'name': 'Someone'})!.subtitle, 'Someone');
      expect(
        parse(<dynamic>[
          <String, dynamic>{'name': 'Someone', 'id': 'UC1'},
          <String, dynamic>{'name': 'Somebody', 'id': 'UC2'},
        ])!.subtitle,
        'Someone, Somebody',
      );
      expect(parse(<dynamic>['Someone', 'Somebody'])!.subtitle,
          'Someone, Somebody');
      expect(parse(null)!.subtitle, isEmpty);
      // A shape this field does not have contributes nothing rather than a
      // stringified Dart value.
      expect(parse(27)!.subtitle, isEmpty);
      expect(parse(<String, dynamic>{'id': 'UC1'})!.subtitle, isEmpty);
    });

    test('a Home rail playlist card names its owner and count', () async {
      // The recorded Home payload really does state a playlist card's owner as
      // a list of objects — the shape that used to reach the UI as
      // "[{name: …}]".
      expect(fixture('home.json'), contains('"author": ['));

      final Map<String, dynamic> owned =
          (jsonDecode(fixture('home.json')) as List<dynamic>)
              .expand((dynamic rail) =>
                  (rail as Map<String, dynamic>)['contents'] as List<dynamic>)
              .whereType<Map<String, dynamic>>()
              .firstWhere((Map<String, dynamic> card) {
        final dynamic author = card['author'];
        return author is List<dynamic> && author.isNotEmpty;
      });
      final String owner =
          ((owned['author'] as List<dynamic>).first as Map<String, dynamic>)['name']
              as String;

      final List<HomeRow> rows = await repositoryOver(recordedSidecar()).home();
      final MediaItem card = rows
          .expand((HomeRow row) => row.items)
          .firstWhere((MediaItem item) => item.title == owned['title']);

      expect(card.collection?.kind, CollectionKind.playlist);
      expect(card.subtitle, isNot(contains('{')));
      expect(card.subtitle, isNot(contains('[')));
      expect(card.subtitle, isNot(contains('name:')));
      expect(card.subtitle, '$owner · ${owned['count']} tracks');
    });

    test('a playlist card with no owner and no count shows no credit line',
        () async {
      // Nine of the recorded Home cards state neither (\"Liked Music\" and the
      // auto-generated mixes); an empty line is what they get.
      final List<HomeRow> rows = await repositoryOver(recordedSidecar()).home();
      final MediaItem bare = rows
          .expand((HomeRow row) => row.items)
          .firstWhere((MediaItem item) =>
              item.collection?.kind == CollectionKind.playlist &&
              item.subtitle.isEmpty);

      expect(bare.title, isNotEmpty);
    });

    test('no subtitle from the real payloads is a stringified object',
        () async {
      final YtmRepository repo = repositoryOver(recordedSidecar());
      final List<MediaItem> items = <MediaItem>[
        for (final HomeRow row in await repo.home()) ...row.items,
      ];
      for (final LibrarySegment segment in LibrarySegment.values) {
        items.addAll(await repo.library(segment));
      }
      final SearchResults results = await repo.search('thriller');
      items.addAll(<MediaItem>[
        ...results.songs,
        ...results.albums,
        ...results.artists,
        ...results.playlists,
      ]);

      expect(items, isNotEmpty);
      for (final MediaItem item in items) {
        expect(
          item.subtitle,
          isNot(matches(RegExp(r'[\[\{].*[\]\}]'))),
          reason: 'subtitle of "${item.title}"',
        );
      }
    });

    test('a duration string parses when duration_seconds is absent', () {
      expect(
        durationOf(<String, dynamic>{'duration': '5:58'}),
        const Duration(minutes: 5, seconds: 58),
      );
      expect(
        durationOf(<String, dynamic>{'duration': '1:02:03'}),
        const Duration(hours: 1, minutes: 2, seconds: 3),
      );
      expect(durationOf(<String, dynamic>{}), isNull);
    });

    test('the largest thumbnail is chosen, not the first', () {
      expect(
        largestThumbnail(<String, dynamic>{
          'thumbnails': <dynamic>[
            <String, dynamic>{'url': 'small', 'width': 60},
            <String, dynamic>{'url': 'large', 'width': 544},
            <String, dynamic>{'url': 'medium', 'width': 226},
          ],
        }),
        'large',
      );
    });
  });
}
