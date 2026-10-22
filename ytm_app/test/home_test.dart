import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ytm_app/core/app_settings.dart';
import 'package:ytm_app/data/api_client.dart';
import 'package:ytm_app/data/ytm_repository.dart';
import 'package:ytm_app/features/home/popular_rail.dart';
import 'package:ytm_app/theme/tokens.dart';
import 'package:ytm_app/ui/media_rows.dart';

import 'support/harness.dart';
import 'support/recorded_sidecar.dart';

/// A `/home` payload that really carries playable rows, so the Popular rail has
/// something to list. The recorded fixture is all albums and playlists, which is
/// exactly the case where the rail must stay hidden.
String homeWithSongs() => jsonEncode(<Map<String, dynamic>>[
      <String, dynamic>{
        'title': 'Quick picks',
        'contents': <Map<String, dynamic>>[
          <String, dynamic>{
            'videoId': 'song0000001',
            'title': 'Popular One',
            'artists': <Map<String, String>>[
              <String, String>{'name': 'Artist One'},
            ],
            'duration': '3:10',
            'duration_seconds': 190,
            'thumbnails': <Map<String, Object>>[
              <String, Object>{'url': 'https://example.invalid/a.jpg', 'width': 500},
            ],
          },
          <String, dynamic>{
            'videoId': 'song0000002',
            'title': 'Popular Two',
            'artists': <Map<String, String>>[
              <String, String>{'name': 'Artist Two'},
            ],
            'duration': '2:45',
            'duration_seconds': 165,
            'thumbnails': <Map<String, Object>>[
              <String, Object>{'url': 'https://example.invalid/b.jpg', 'width': 500},
            ],
          },
        ],
      },
    ]);

/// The artist id the recorded Home album credits (`artists[0].id`).
const String kFeaturedArtistId = 'UC5275386193416ad3';

void main() {
  setUpAll(loadAppFonts);

  testWidgets('the hero shows the featured release with Play and Follow',
      (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/home'),
      size: kDesktop,
    );

    // The first album the feed offers is the feature, and it has both actions.
    expect(find.text('Play'), findsOneWidget);
    expect(find.text('Follow'), findsOneWidget);
  });

  testWidgets('the Popular rail is a desktop-only rail',
      (WidgetTester tester) async {
    final YtmRepository repository =
        testRepository(responses: <String, http.Response>{
      '/home': jsonOk(homeWithSongs()),
    });

    await pumpAtSize(
      tester,
      appScope(initialLocation: '/home', repository: repository),
      size: kDesktop,
    );

    expect(find.byType(PopularRail), findsOneWidget);
    expect(find.text('Popular'), findsOneWidget);
    // Numbered, in service order.
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('Popular One'), findsWidgets);

    // Narrow widths collapse it away entirely rather than stacking it.
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/home', repository: repository),
      size: kPhone,
    );

    expect(find.byType(PopularRail), findsNothing);
    expect(find.text('Popular'), findsNothing);
  });

  testWidgets('the Popular rail stays hidden when the feed has nothing to play',
      (WidgetTester tester) async {
    // Collections open pages; they are not tracks, so a feed of only albums and
    // playlists must leave the rail out rather than invent entries for it.
    final YtmRepository repository =
        testRepository(responses: <String, http.Response>{
      '/home': jsonOk(
        '[{"title":"From your library","contents":['
        '{"title":"A mix","playlistId":"PL1234567890",'
        '"thumbnails":[{"url":"https://example.invalid/c.jpg","width":500}]}]}]',
      ),
      // Nothing to blend, so the feed stays exactly as the test set it up.
      '/recommendations/home': jsonOk(
        '{"title":"Recommended for you","items":[],"count":0}',
      ),
    });

    await pumpAtSize(
      tester,
      appScope(initialLocation: '/home', repository: repository),
      size: kDesktop,
    );

    expect(find.byType(PopularRail), findsNothing);
  });

  testWidgets('tapping a Popular row plays it through the shared player',
      (WidgetTester tester) async {
    final YtmRepository repository =
        testRepository(responses: <String, http.Response>{
      '/home': jsonOk(homeWithSongs()),
    });

    await pumpAtSize(
      tester,
      appScope(initialLocation: '/home', repository: repository),
      size: kDesktop,
    );

    await tester.tap(find.text('Popular One').first);
    await tester.pumpAndSettle();

    // The Now Playing bar is the shell's view of the shared controller, so a title
    // there proves the row really queued and started.
    expect(
      find.descendant(
        of: find.byType(Scaffold).first,
        matching: find.text('Popular One'),
      ),
      findsWidgets,
    );
  });

  testWidgets('Follow subscribes the featured artist through the sidecar',
      (WidgetTester tester) async {
    final List<http.Request> requests = <http.Request>[];
    bool subscribed = false;

    final YtmRepository repository = YtmRepository(
      YtmApiClient(
        client: MockClient((http.Request request) async {
          requests.add(request);
          if (request.url.path == '/library/subscriptions') {
            if (request.method == 'POST') {
              final Map<String, dynamic> body =
                  jsonDecode(request.body) as Map<String, dynamic>;
              subscribed = body['subscribed'] == true;
              return jsonOk('{"subscribed":true}');
            }
            return jsonOk(
              subscribed
                  ? '[{"browseId":"$kFeaturedArtistId","artist":"Artist 744"}]'
                  : '[]',
            );
          }
          return recordedResponse(request);
        }),
        readPortFile: () async => '8000',
      ),
    );

    await pumpAtSize(
      tester,
      appScope(initialLocation: '/home', repository: repository),
      size: kDesktop,
    );

    expect(find.text('Follow'), findsOneWidget);
    await tester.tap(find.text('Follow'));
    await tester.pumpAndSettle();

    // The write really happened, with the featured artist's channel id...
    final http.Request post = requests.firstWhere(
      (http.Request request) =>
          request.url.path == '/library/subscriptions' &&
          request.method == 'POST',
    );
    final Map<String, dynamic> body =
        jsonDecode(post.body) as Map<String, dynamic>;
    expect(body['artistId'], kFeaturedArtistId);
    expect(body['subscribed'], isTrue);

    // ...and the button reads the new state back off the sidecar.
    expect(find.text('Following'), findsOneWidget);
    expect(find.text('Follow'), findsNothing);
  });

  testWidgets(
      'Follow starts from the real subscription the sidecar reports, not a guess',
      (WidgetTester tester) async {
    // The account already follows this artist. Nothing is cached locally, so
    // the only way the button can know is by reading it back.
    final List<http.Request> writes = <http.Request>[];
    final YtmRepository repository = YtmRepository(
      YtmApiClient(
        client: MockClient((http.Request request) async {
          if (request.url.path == '/library/subscriptions') {
            writes.add(request);
            return jsonOk('[{"browseId":"$kFeaturedArtistId"}]');
          }
          return recordedResponse(request);
        }),
        readPortFile: () async => '8000',
      ),
    );

    await pumpAtSize(
      tester,
      appScope(initialLocation: '/home', repository: repository),
      size: kDesktop,
    );

    expect(find.text('Following'), findsOneWidget);
    expect(find.text('Follow'), findsNothing);
    // Loading state is a read only: nothing was written to the account.
    expect(
      writes.where((http.Request r) => r.method == 'POST'),
      isEmpty,
    );
  });

  testWidgets('a failed write rolls Follow back and says so',
      (WidgetTester tester) async {
    final YtmRepository repository = YtmRepository(
      YtmApiClient(
        client: MockClient((http.Request request) async {
          if (request.url.path == '/library/subscriptions' &&
              request.method == 'POST') {
            // A real write takes a round trip; the delay keeps it in flight for
            // exactly one frame so the optimistic label can be observed.
            await Future<void>.delayed(const Duration(milliseconds: 20));
            return http.Response(
              '{"detail":"YouTube Music request failed. Try again shortly."}',
              502,
            );
          }
          return recordedResponse(request);
        }),
        readPortFile: () async => '8000',
      ),
    );

    await pumpAtSize(
      tester,
      appScope(initialLocation: '/home', repository: repository),
      size: kDesktop,
    );

    await tester.tap(find.text('Follow'));
    // Optimistic: the label flips on the tap's own frame, before the round trip.
    await tester.pump();
    expect(find.text('Following'), findsOneWidget);

    await tester.pumpAndSettle();

    // The write failed, so the button goes back to what the account is in...
    expect(find.text('Follow'), findsOneWidget);
    expect(find.text('Following'), findsNothing);
    // ...and the failure is reported in one short snackbar.
    expect(
      find.text('YouTube Music request failed. Try again shortly.'),
      findsOneWidget,
    );
  });

  testWidgets('an expired session rolls Follow back instead of faking a follow',
      (WidgetTester tester) async {
    final YtmRepository repository = YtmRepository(
      YtmApiClient(
        client: MockClient((http.Request request) async {
          if (request.url.path == '/library/subscriptions' &&
              request.method == 'POST') {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            return http.Response('{"detail":"Not signed in."}', 401);
          }
          return recordedResponse(request);
        }),
        readPortFile: () async => '8000',
      ),
    );

    await pumpAtSize(
      tester,
      appScope(initialLocation: '/home', repository: repository),
      size: kDesktop,
    );

    await tester.tap(find.text('Follow'));
    await tester.pump();
    expect(find.text('Following'), findsOneWidget);

    await tester.pumpAndSettle();

    expect(find.text('Follow'), findsOneWidget);
    expect(find.text('Not signed in.'), findsOneWidget);
  });

  testWidgets('Home cards ellipsize rather than overflow at the maximum scale',
      (WidgetTester tester) async {
    final YtmRepository repository =
        testRepository(responses: <String, http.Response>{
      '/home': jsonOk(homeWithLongTitles()),
      // Nothing to blend, so the cards under test are the feed's own.
      '/recommendations/home': jsonOk(
        '{"title":"Recommended for you","items":[],"count":0}',
      ),
    });

    await pumpAtSize(
      tester,
      appScope(
        initialLocation: '/home',
        repository: repository,
        // The app boots at the standard scale now, so "maximum scale" has to be
        // asked for: both the platform value and the user's own ceiling.
        extraOverrides: [
          initialAppSettingsProvider.overrideWithValue(
            const AppSettings(textScale: Tokens.textScaleCap),
          ),
        ],
      ),
      size: kPhone,
      textScale: kAccessibleTextScale,
    );

    // The scale really is the maximum, so this is the case that matters.
    expect(
      MediaQuery.textScalerOf(
        tester.element(find.byType(MediaCard).first),
      ).scale(1),
      Tokens.textScaleCap,
    );

    final Finder card = find.byType(MediaCard).first;
    final Finder title = find.descendant(
      of: card,
      matching: find.text(kLongCardTitle),
    );
    final Finder subtitle = find.descendant(
      of: card,
      matching: find.text(kLongCardSubtitle),
    );
    expect(title, findsOneWidget);
    expect(subtitle, findsOneWidget);

    // Both lines are single-line and ellipsized by construction...
    for (final Finder line in <Finder>[title, subtitle]) {
      final Text widget = tester.widget<Text>(line);
      expect(widget.maxLines, 1);
      expect(widget.overflow, TextOverflow.ellipsis);
      // ...and the truncated line stays inside its card instead of painting
      // past it — which is what the large text scale would otherwise cause.
      expect(
        tester.getSize(line).width,
        lessThanOrEqualTo(tester.getSize(card).width),
      );
      expect(tester.getSize(line).height, greaterThan(0));
    }

    // A RenderFlex overflow would surface here; there must be none.
    expect(tester.takeException(), isNull);
  });
}

/// A `/home` payload whose card text is far longer than one line can hold at
/// the maximum text scale, so the ellipsis has something to do.
String homeWithLongTitles() => jsonEncode(<Map<String, dynamic>>[
      <String, dynamic>{
        'title': 'A shelf heading long enough to need the whole width',
        'contents': <Map<String, dynamic>>[
          <String, dynamic>{
            'videoId': 'song0000003',
            'title': kLongCardTitle,
            'artists': <Map<String, String>>[
              <String, String>{'name': kLongCardSubtitle},
            ],
            'duration': '3:10',
            'duration_seconds': 190,
            'thumbnails': <Map<String, Object>>[
              <String, Object>{
                'url': 'https://example.invalid/long.jpg',
                'width': 500,
              },
            ],
          },
          // Filler so the shelf clears the minimum-rail threshold and still
          // renders: this test is about card typography, not about shelves
          // that are too thin to show.
          for (final String id in <String>['song0000004', 'song0000005'])
            <String, dynamic>{
              'videoId': id,
              'title': 'Filler $id',
              'artists': <Map<String, String>>[
                <String, String>{'name': 'Filler Artist'},
              ],
              'duration': '3:00',
              'duration_seconds': 180,
              'thumbnails': <Map<String, Object>>[
                <String, Object>{
                  'url': 'https://example.invalid/$id.jpg',
                  'width': 500,
                },
              ],
            },
        ],
      },
    ]);

const String kLongCardTitle =
    'A deliberately overlong song title that no single artwork card line can '
    'ever show in full at the maximum text scale';

const String kLongCardSubtitle =
    'A featured artist credit with an unusually long display name, longer than '
    'the card is wide';
