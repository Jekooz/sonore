import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ytm_app/audio/track.dart';
import 'package:ytm_app/data/models.dart';
import 'package:ytm_app/data/ytm_repository.dart';

import 'support/harness.dart';
import 'support/recorded_sidecar.dart';

/// The app's side of the layered recommender.
///
/// The tests drive the real repository and the real API client over the
/// recorded sidecar, so the wiring is exercised end to end: which route the
/// app asks for, and what it does when that route fails.
void main() {
  setUpAll(loadAppFonts);

  group('the home recommendation row', () {
    testWidgets('is filled by the blended route', (WidgetTester tester) async {
      final YtmRepository repository = testRepository(
        responses: <String, http.Response>{'/home': jsonOk(_homeWithRecommendation)},
      );

      final List<HomeRow> rows = await repository.home();

      final HomeRow row = rows.firstWhere(
        (HomeRow row) => row.title == 'Recommended for you',
      );
      // The service's own pick is gone; the blended one is there.
      expect(
        row.items.map((MediaItem item) => item.title),
        <String>['Blended Pick'],
      );
    });

    testWidgets('keeps the service\'s own row when the route fails',
        (WidgetTester tester) async {
      final YtmRepository repository = testRepository(
        responses: <String, http.Response>{
          '/home': jsonOk(_homeWithRecommendation),
          '/recommendations/home': http.Response('{"detail":"boom"}', 500),
        },
      );

      final List<HomeRow> rows = await repository.home();

      final HomeRow row = rows.firstWhere(
        (HomeRow row) => row.title == 'Recommended for you',
      );
      expect(
        row.items.map((MediaItem item) => item.title),
        <String>['Service Pick'],
      );
    });

    testWidgets('is added when the feed has no such row',
        (WidgetTester tester) async {
      final YtmRepository repository = testRepository();

      final List<HomeRow> rows = await repository.home();

      // The recorded feed has no recommendation row, so the blended one is
      // added at the top: a recommendation nobody sees is not a recommendation.
      expect(rows.first.title, 'Recommended for you');
      expect(
        rows.first.items.map((MediaItem item) => item.title),
        <String>['Blended Pick'],
      );
      // The service's own rows are all still there.
      expect(rows.length, greaterThan(1));
    });

    testWidgets('is left out when the route fails', (WidgetTester tester) async {
      final YtmRepository repository = testRepository(
        responses: <String, http.Response>{
          '/recommendations/home': http.Response('{"detail":"boom"}', 500),
        },
      );

      final List<HomeRow> rows = await repository.home();

      expect(
        rows.map((HomeRow row) => row.title),
        isNot(contains('Recommended for you')),
      );
    });

    testWidgets('does not take over a row that only says "for you"',
        (WidgetTester tester) async {
      final YtmRepository repository = testRepository(
        responses: <String, http.Response>{
          '/home': jsonOk(_homeWithAlbumsForYou),
        },
      );

      final List<HomeRow> rows = await repository.home();

      // "Albums for you" is the service's own row of albums, not the row the
      // blended recommendations belong in.
      final HomeRow albums = rows.firstWhere(
        (HomeRow row) => row.title == 'Albums for you',
      );
      expect(albums.items.map((MediaItem item) => item.title), <String>['An Album']);
      // And the blended row was added beside it.
      expect(
        rows.map((HomeRow row) => row.title),
        contains('Recommended for you'),
      );
    });
  });

  group('autoplay', () {
    testWidgets('asks the blended route first', (WidgetTester tester) async {
      final YtmRepository repository = testRepository();

      final List<Track> tracks = await repository.recommendations(
        _seed,
        exclude: const <String>['queued0000001'],
      );

      expect(tracks.map((Track track) => track.id), contains('blended000002'));
    });

    testWidgets('falls back to the old route when the new one fails',
        (WidgetTester tester) async {
      final YtmRepository repository = testRepository(
        responses: <String, http.Response>{
          '/recommendations/next': http.Response('{"detail":"boom"}', 500),
        },
      );

      final List<Track> tracks = await repository.recommendations(_seed);

      // The recorded /recommendations payload answered instead.
      expect(tracks, isNotEmpty);
      expect(
        tracks.map((Track track) => track.id),
        isNot(contains('blended000002')),
      );
    });
  });

  group('taste events', () {
    testWidgets('a play is reported and never throws', (
      WidgetTester tester,
    ) async {
      final YtmRepository repository = testRepository();

      await repository.reportTasteEvent('play', _seedTrack, completed: true);
    });

    testWidgets('a failing service does not fail the report', (
      WidgetTester tester,
    ) async {
      final YtmRepository repository = testRepository(
        responses: <String, http.Response>{
          '/events/play': http.Response('{"detail":"boom"}', 500),
        },
      );

      // The report is fire and forget: the app must not see the failure.
      await repository.reportTasteEvent('play', _seedTrack, completed: true);
    });
  });

  group('the recommendation settings', () {
    testWidgets('are read back from the service', (WidgetTester tester) async {
      final YtmRepository repository = testRepository();

      final RecommenderSettings settings =
          await repository.recommenderSettings();

      expect(settings.localLearning, isTrue);
      expect(settings.listenbrainzUser, 'jekooz');
      expect(settings.externalConfigured, isFalse);
    });
  });
}

final Track _seedTrack = Track(
  id: 'seed000000001',
  title: 'Seed Track',
  artist: 'Seed Artist',
  album: 'Seed Album',
  duration: const Duration(minutes: 3, seconds: 7),
);

const Track _seed = Track(
  id: 'seed000000001',
  title: 'Seed Track',
  artist: 'Seed Artist',
  album: 'Seed Album',
  duration: Duration(minutes: 3, seconds: 7),
);

/// A home feed that carries the service's own recommendation row, so the
/// blending can be seen replacing it.
const String _homeWithRecommendation = '''
[
  {
    "title": "Recommended for you",
    "contents": [
      {
        "videoId": "service000001",
        "title": "Service Pick",
        "artists": [{"name": "Service Artist", "id": "UCservice001"}],
        "thumbnails": [
          {"url": "https://example.invalid/art/service-120.jpg", "width": 120, "height": 120}
        ],
        "duration": "3:07",
        "durationSeconds": 187
      }
    ]
  },
  {
    "title": "Listen again",
    "contents": [
      {
        "videoId": "service000002",
        "title": "Older Pick",
        "artists": [{"name": "Service Artist", "id": "UCservice001"}],
        "thumbnails": [
          {"url": "https://example.invalid/art/service-120.jpg", "width": 120, "height": 120}
        ],
        "duration": "3:07",
        "durationSeconds": 187
      }
    ]
  }
]
''';

/// A home feed with a row that only says "for you" — the service's own albums,
/// which the blended recommendations must not take over.
const String _homeWithAlbumsForYou = '''
[
  {
    "title": "Albums for you",
    "contents": [
      {
        "title": "An Album",
        "browseId": "MPREb_album00001",
        "artists": [{"name": "Service Artist", "id": "UCservice001"}],
        "thumbnails": [
          {"url": "https://example.invalid/art/album-120.jpg", "width": 120, "height": 120}
        ]
      }
    ]
  }
]
''';
