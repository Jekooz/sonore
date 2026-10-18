import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:riverpod/misc.dart' show Override;
import 'package:ytm_app/audio/equalizer.dart';
import 'package:ytm_app/core/app_settings.dart';
import 'package:ytm_app/core/folder_reveal.dart';
import 'package:ytm_app/data/models.dart';
import 'package:ytm_app/features/collection/collection_screen.dart';
import 'package:ytm_app/features/settings/settings_screen.dart';
import 'package:ytm_app/features/shell/mini_player.dart';
import 'package:ytm_app/theme/icons.dart';
import 'package:ytm_app/theme/tokens.dart';
import 'package:ytm_app/ui/data_states.dart';
import 'package:ytm_app/ui/media_rows.dart';
import 'package:ytm_app/ui/pill_button.dart';
import 'package:ytm_app/ui/screen_header.dart';

import 'support/harness.dart';
import 'support/recorded_sidecar.dart';

/// The product screens against the recorded sidecar payloads.
///
/// Every expectation is read from the payload the app actually receives, so a
/// re-recorded fixture updates the assertion with it instead of leaving a
/// hard-coded copy behind. Nothing here is a stand-in for the app's own code
/// path: the real repository, parsers, routers and controllers all run.

/// The recorded payload for [name], decoded.
dynamic fixtureJson(String name) => jsonDecode(fixture(name));

/// The titles of the first segment's rows, in service order.
List<String> rowTitles(String fixtureName) =>
    (fixtureJson(fixtureName) as List<dynamic>)
        .map(
          (dynamic entry) =>
              ((entry as Map<String, dynamic>)['title'] ?? '') as String,
        )
        .toList(growable: false);

/// Waits out the search field's debounce and settles the request it issues.
Future<void> settleSearch(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
}

/// The overflow button of the first row.
///
/// Scoping matters: the shell's nav rail carries a Settings action drawn with
/// the same `dotsThree` glyph and it precedes the content in tree order, so an
/// unscoped `find.byIcon(AppIcons.dotsThree).first` would tap Settings.
Finder firstRowOverflow() => find.descendant(
  of: find.byType(MediaRow).first,
  matching: find.byIcon(AppIcons.dotsThree),
);

/// Opens the Library's Songs segment and returns the row titles in order.
Future<List<String>> openSongs(WidgetTester tester) async {
  await tester.tap(find.text('Songs').first);
  await tester.pumpAndSettle();
  return tester
      .widgetList<MediaRow>(find.byType(MediaRow))
      .map((MediaRow row) => row.item.title)
      .toList(growable: false);
}

/// Selects a Library segment by its chip label.
///
/// The chip row scrolls horizontally, so the later segments are not always on
/// screen; this scrolls the chip into view before tapping it.
Future<void> tapLibrarySegment(WidgetTester tester, String label) async {
  final Finder chip = find.text(label);
  expect(chip, findsWidgets, reason: 'the "$label" chip is not in the row');
  await tester.ensureVisible(chip.first);
  await tester.pumpAndSettle();
  await tester.tap(chip.first);
  await tester.pumpAndSettle();
}

/// Scrolls the Settings list until [finder] is in the tree and on screen.
///
/// The page is one lazily-built list, so anything below the fold — the Account
/// section, the buttons at the bottom — is not in the tree until it is
/// scrolled to.
Future<void> scrollSettingsTo(
  WidgetTester tester,
  Finder finder, {
  double dy = -300,
}) async {
  final Finder list = find.descendant(
    of: find.byType(SettingsScreen),
    matching: find.byType(ListView),
  );
  for (int i = 0; i < 40 && finder.evaluate().isEmpty; i++) {
    await tester.drag(list, Offset(0, dy));
    await tester.pumpAndSettle();
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

/// Scrolls the search results until [text] is on screen.
///
/// The results are one lazily-built list, so a group below the fold is not in
/// the tree until it is scrolled to; asserting them all without scrolling would
/// only ever find the first group.
Future<void> scrollToInResults(WidgetTester tester, String text) async {
  // The results are a single ListView; dragging the list itself (rather than a
  // row, whose own gestures swallow the drag) reveals each group in turn.
  for (int i = 0; i < 40 && find.text(text).evaluate().isEmpty; i++) {
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
  }
}

void main() {
  setUpAll(loadAppFonts);

  group('home', () {
    testWidgets('renders every rail the service returned, with real cards', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/home'),
        size: kDesktop,
      );

      expect(find.text('Good evening'), findsOneWidget);
      for (final String title in rowTitles('home.json')) {
        expect(find.text(title), findsWidgets, reason: 'rail $title');
      }
      expect(find.byType(MediaCard), findsWidgets);
      // Three recorded rails of 20, 10 and 20 cards: the rail is a real
      // horizontal list, so more than a handful are built.
      expect(find.byType(MediaCard).evaluate().length, greaterThan(4));
    });

    testWidgets('is offline, not broken, when the service is not running', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/home', repository: offlineRepository()),
        size: kPhone,
      );

      expect(find.text('YouTube Music is not reachable.'), findsOneWidget);
      // The distinction is deliberate: the service is local, so this must not
      // claim the device has no network.
      expect(
        find.textContaining('Nothing is stored on this device'),
        findsOneWidget,
      );
      expect(find.text('Try again'), findsOneWidget);
      expect(find.byType(MediaCard), findsNothing);
    });

    testWidgets('offers the real sign-in hand-off when the session is gone', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/home', repository: signedOutRepository()),
        size: kPhone,
      );

      expect(find.text('Not signed in to YouTube Music.'), findsOneWidget);
      expect(find.text('Sign in'), findsOneWidget);
    });

    testWidgets('names the extension folder sign-in cannot finish without, and '
        'can open it', (WidgetTester tester) async {
      // The hand-off only completes through the helper extension, and only when
      // it was loaded from this folder. Without that on screen, the three-minute
      // wait that follows reads as a sign-in screen that simply does not work.
      final List<String> revealed = <String>[];
      await pumpAtSize(
        tester,
        appScope(
          initialLocation: '/home',
          repository: signedOutRepository(),
          extraOverrides: <Override>[
            folderRevealerProvider.overrideWithValue(
              (String path) async => revealed.add(path),
            ),
          ],
        ),
        size: kPhone,
      );

      expect(find.text('Not signed in to YouTube Music.'), findsOneWidget);
      expect(
        find.textContaining(r'C:\Program Files\Sonore\browser-extension'),
        findsOneWidget,
      );

      await tester.tap(find.text('Open extension folder'));
      await tester.pumpAndSettle();

      expect(revealed, <String>[r'C:\Program Files\Sonore\browser-extension']);
    });

    testWidgets('the sign-in instructions still fit at the accessibility text '
        'scale', (WidgetTester tester) async {
      // This copy is long by necessity: it names a folder and a manual step. A
      // column that no longer fits reports a RenderFlex overflow, which fails
      // this test rather than reaching a user as a clipped sentence.
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/home', repository: signedOutRepository()),
        size: kPhone,
        textScale: kAccessibleTextScale,
      );

      expect(find.text('Not signed in to YouTube Music.'), findsOneWidget);
      expect(find.text('Sign in'), findsOneWidget);
      expect(find.text('Open extension folder'), findsOneWidget);
    });

    testWidgets('shows a skeleton until the service answers', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/home', repository: pendingRepository()),
        size: kPhone,
        settle: false,
      );

      expect(find.byType(ListSkeleton), findsOneWidget);
      expect(find.byType(MediaCard), findsNothing);

      // Let the slow probe finish so the test ends with nothing scheduled.
      // The answers land inside the client's 2s deadline, so this single pump
      // both settles the probe and leaves no timer behind.
      await tester.pump(const Duration(seconds: 2));
    });
  });

  group('search', () {
    testWidgets('before a query it explains what search does', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/search'),
        size: kPhone,
      );

      expect(find.text('Search YouTube Music.'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byType(MediaRow), findsNothing);
    });

    testWidgets('waits out the debounce, then groups the real results', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/search'),
        size: kPhone,
      );

      await tester.enterText(find.byType(TextField), 'thriller');
      await tester.pump(const Duration(milliseconds: 100));
      // 100ms in, the 300ms debounce has not fired: no results yet.
      expect(find.text('Songs'), findsNothing);

      await settleSearch(tester);

      // The recorded search returns songs, videos, episodes, albums, an artist
      // and a playlist, so all four groups are present — each revealed by
      // scrolling the one lazy result list to it.
      for (final String group in <String>[
        'Songs',
        'Albums',
        'Artists',
        'Playlists',
      ]) {
        await scrollToInResults(tester, group);
        expect(find.text(group), findsOneWidget, reason: group);
      }
      expect(find.byType(MediaRow), findsWidgets);
    });

    testWidgets('a query with no results names the query', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(
          initialLocation: '/search',
          repository: testRepository(
            responses: <String, http.Response>{'/search': jsonOk('[]')},
          ),
        ),
        size: kPhone,
      );

      await tester.enterText(find.byType(TextField), 'zzzznothing');
      await settleSearch(tester);

      expect(find.textContaining('No results for'), findsOneWidget);
      expect(find.textContaining('zzzznothing'), findsWidgets);
      expect(find.byType(MediaRow), findsNothing);
    });

    testWidgets('a failed search keeps the service words and offers retry', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(
          initialLocation: '/search',
          repository: testRepository(
            responses: <String, http.Response>{
              '/search': http.Response(
                '{"detail":"Search is unavailable."}',
                502,
              ),
            },
          ),
        ),
        size: kPhone,
      );

      await tester.enterText(find.byType(TextField), 'thriller');
      await settleSearch(tester);

      expect(find.text('Search is unavailable.'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('a completed search is remembered and replayable', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/search'),
        size: kPhone,
      );

      await tester.enterText(find.byType(TextField), 'thriller');
      await settleSearch(tester);
      expect(find.text('Songs'), findsOneWidget);

      await tester.tap(find.byIcon(AppIcons.close));
      await tester.pumpAndSettle();

      expect(find.text('Songs'), findsNothing);
      expect(find.text('Recent searches'), findsOneWidget);
      expect(find.text('thriller'), findsWidgets);
    });

    testWidgets('tapping a recent search runs it again', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/search'),
        size: kPhone,
      );

      await tester.enterText(find.byType(TextField), 'thriller');
      await settleSearch(tester);
      await tester.tap(find.byIcon(AppIcons.close));
      await tester.pumpAndSettle();

      // The remembered query is the row under the heading; tapping it searches
      // again rather than just refilling the field.
      await tester.tap(find.text('thriller').last);
      await settleSearch(tester);

      expect(find.text('Songs'), findsOneWidget);
    });
  });

  group('library', () {
    testWidgets('shows the segment chips and the rows of the selected one', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/library'),
        size: kDesktop,
      );

      expect(find.text('Library'), findsWidgets);
      for (final LibrarySegment segment in LibrarySegment.values) {
        expect(find.text(segment.label), findsWidgets, reason: segment.label);
      }
      expect(find.byType(MediaRow), findsWidgets);
    });

    testWidgets('the Songs segment is playable rows, not collection links', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/library'),
        size: kDesktop,
      );

      final List<String> titles = await openSongs(tester);

      // Rows are built lazily, so what is on screen is the head of the service
      // order — but it must be exactly that, in that order.
      expect(titles.length, greaterThan(3));
      expect(
        titles,
        rowTitles('library_songs.json').take(titles.length).toList(),
      );
      final MediaRow row = tester.widget<MediaRow>(find.byType(MediaRow).first);
      expect(row.item.isPlayable, isTrue);
      expect(row.item.track!.albumId, isNotNull);
    });

    testWidgets('the sort menu offers only implemented orders', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/library'),
        size: kDesktop,
      );

      await tester.tap(find.text('Service order'));
      await tester.pumpAndSettle();

      expect(find.text('A–Z'), findsOneWidget);
      // The app does keep its own listening history, but as a segment of its
      // own: the service's lists carry no added date, and a sort key the rows
      // do not have would be a lie rather than an unimplemented feature.
      expect(find.textContaining('Recently added'), findsNothing);
      expect(find.textContaining('Recently played'), findsNothing);
    });

    testWidgets('A–Z really reorders the rows', (WidgetTester tester) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/library'),
        size: kDesktop,
      );

      List<String> titlesOnScreen() => tester
          .widgetList<MediaRow>(find.byType(MediaRow))
          .map((MediaRow row) => row.item.title)
          .toList(growable: false);

      final List<String> before = titlesOnScreen();
      await tester.tap(find.text('Service order'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('A–Z'));
      await tester.pumpAndSettle();
      final List<String> after = titlesOnScreen();

      expect(after, isNotEmpty);
      expect(after, isNot(equals(before)));
      final List<String> sorted = List<String>.of(after)
        ..sort(
          (String a, String b) => a.toLowerCase().compareTo(b.toLowerCase()),
        );
      expect(after, sorted);
    });

    testWidgets('an empty segment says so plainly', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(
          initialLocation: '/library',
          repository: testRepository(
            responses: <String, http.Response>{
              '/library/playlists': jsonOk('[]'),
            },
          ),
        ),
        size: kPhone,
      );

      expect(find.text('No playlists in your library.'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
      expect(find.byType(MediaRow), findsNothing);
    });

    testWidgets('the History segment lists what this app really played', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(
          initialLocation: '/library',
          repository: testRepository(
            responses: <String, http.Response>{
              // The sidecar's own store shape: newest first.
              '/listening/history': jsonOk(
                '{"entries":['
                '{"videoId":"dQw4w9WgXcQ","title":"Played Later",'
                '"artist":"Nova","plays":2,"lastAt":1700000200,'
                '"lastOutcome":"skipped"},'
                '{"videoId":"jNQXAC9IVRw","title":"Played First",'
                '"artist":"Kite Club","plays":1,"lastAt":1700000100,'
                '"lastOutcome":"completed"}],"count":2}',
              ),
            },
          ),
        ),
        size: kDesktop,
      );

      await tapLibrarySegment(tester, 'History');

      final List<MediaRow> rows =
          tester.widgetList<MediaRow>(find.byType(MediaRow)).toList();
      expect(
        rows.map((MediaRow row) => row.item.title),
        <String>['Played Later', 'Played First'],
        reason: 'newest first',
      );
      expect(rows.first.item.isPlayable, isTrue);
      expect(rows.first.item.subtitle, 'Nova');
    });

    testWidgets('an empty history says nothing has been played, not that '
        'nothing was saved', (WidgetTester tester) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/library'),
        size: kDesktop,
      );

      await tapLibrarySegment(tester, 'History');

      expect(find.text('Nothing played yet.'), findsOneWidget);
      expect(find.byType(MediaRow), findsNothing);
    });
  });

  group('collection page', () {
    testWidgets('an album page shows its real header and tracks', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/library/collection/album/MPREb_test'),
        size: kDesktop,
      );

      expect(find.byType(CollectionScreen), findsOneWidget);
      expect(find.text('ALBUM'), findsOneWidget);
      expect(find.text('Play'), findsOneWidget);
      expect(find.text('Add to queue'), findsOneWidget);

      final Map<String, dynamic> album =
          fixtureJson('album.json') as Map<String, dynamic>;
      expect(find.text(album['title'] as String), findsWidgets);
      // Every recorded track carries a videoId, so every one is a real row.
      final int tracks = (album['tracks'] as List<dynamic>).length;
      expect(tracks, greaterThan(1));
      expect(find.byType(MediaRow), findsWidgets);
    });

    testWidgets('Play queues the whole tracklist through the controller', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/library/collection/album/MPREb_test'),
        size: kDesktop,
      );

      // Nothing is playing, so there is no mini player yet.
      expect(find.byType(MiniPlayer), findsNothing);

      final Map<String, dynamic> album =
          fixtureJson('album.json') as Map<String, dynamic>;
      final String firstTrack =
          ((album['tracks'] as List<dynamic>).first
                  as Map<String, dynamic>)['title']
              as String;

      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();

      // The mini player is the shell's view of the shared controller, so its
      // appearing with the album's first track proves the queue was filled and
      // started there rather than a single row being played.
      expect(find.byType(MiniPlayer), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(MiniPlayer),
          matching: find.text(firstTrack),
        ),
        findsOneWidget,
      );
    });

    testWidgets('an unknown collection path says so', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/library/collection/nonsense/x'),
        size: kPhone,
      );

      expect(find.text('That page does not exist.'), findsOneWidget);
    });

    testWidgets('a failed page load keeps the words and offers retry', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(
          initialLocation: '/library/collection/album/MPREb_x',
          repository: testRepository(
            responses: <String, http.Response>{
              '/album/MPREb_x': http.Response(
                '{"detail":"Album unavailable."}',
                502,
              ),
            },
          ),
        ),
        size: kPhone,
      );

      expect(find.text('Album unavailable.'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });
  });

  group('context menu', () {
    testWidgets('a playlist row offers only actions the service supports', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/library'),
        size: kDesktop,
      );

      await tester.tap(firstRowOverflow());
      await tester.pumpAndSettle();

      expect(find.text('Play now'), findsOneWidget);
      expect(find.text('Play next'), findsOneWidget);
      expect(find.text('Add to queue'), findsOneWidget);
      expect(find.text('Copy link'), findsOneWidget);
      // A playlist row is not a song, so it has no like to toggle.
      expect(find.text('Like'), findsNothing);
      // The sidecar has no endpoint for these, so they must not appear at all.
      expect(find.text('Rename'), findsNothing);
      expect(find.text('Edit playlist'), findsNothing);
      expect(find.text('Delete playlist'), findsNothing);
    });

    testWidgets('a song row adds like and the real navigation targets', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/library'),
        size: kDesktop,
      );

      await openSongs(tester);
      final MediaRow first = tester.widget<MediaRow>(
        find.byType(MediaRow).first,
      );
      await tester.tap(firstRowOverflow());
      await tester.pumpAndSettle();

      // The recorded songs carry both ids, so both targets are real.
      expect(find.text('Go to album'), findsOneWidget);
      expect(find.text('Go to artist'), findsOneWidget);
      // The entry reflects the service's persisted rating, so a liked fixture
      // song offers the un-like and an unliked one offers the like.
      expect(
        find.text(first.item.track!.isLiked ? 'Remove like' : 'Like'),
        findsOneWidget,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Play now'), findsNothing);
    });

    testWidgets('right-click opens the same menu as the overflow button', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/library'),
        size: kDesktop,
      );

      await tester.tapAt(
        tester.getCenter(find.byType(MediaRow).first),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();

      expect(find.text('Play now'), findsOneWidget);
      expect(find.text('Add to queue'), findsOneWidget);
    });

    testWidgets('Play now queues the row inside its own list', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/library'),
        size: kDesktop,
      );

      final List<String> songs = await openSongs(tester);
      await tester.tap(firstRowOverflow());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Play now'));
      await tester.pumpAndSettle();

      expect(find.byType(MiniPlayer), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(MiniPlayer),
          matching: find.text(songs.first),
        ),
        findsOneWidget,
      );
    });

    testWidgets('Play next inserts without discarding the queue', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(
          initialLocation: '/library',
          queue: testQueue(),
          queueIndex: 0,
        ),
        size: kDesktop,
      );

      expect(
        find.descendant(
          of: find.byType(MiniPlayer),
          matching: find.text('Falling For You'),
        ),
        findsOneWidget,
      );

      final List<String> songs = await openSongs(tester);
      await tester.tap(firstRowOverflow());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Play next'));
      await tester.pumpAndSettle();

      // The current track is untouched: Play next inserted after it.
      expect(
        find.descendant(
          of: find.byType(MiniPlayer),
          matching: find.text('Falling For You'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byIcon(AppIcons.skipForward));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(MiniPlayer),
          matching: find.text(songs.first),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a collection card offers queueing but no like', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/library'),
        size: kDesktop,
      );

      await tester.tap(find.text('Albums').first);
      await tester.pumpAndSettle();
      await tester.tap(firstRowOverflow());
      await tester.pumpAndSettle();

      expect(find.text('Play now'), findsOneWidget);
      expect(find.text('Play next'), findsOneWidget);
      expect(find.text('Add to queue'), findsOneWidget);
      expect(find.text('Like'), findsNothing);
      expect(find.text('Copy link'), findsOneWidget);
    });
  });

  group('settings', () {
    bool switchValue(WidgetTester tester, String title) =>
        tester.widget<SwitchListTile>(
          find.widgetWithText(SwitchListTile, title),
        ).value;

    testWidgets('the Playback switches write through to the real store',
        (WidgetTester tester) async {
      final InMemorySettingsStore store = InMemorySettingsStore();
      await pumpAtSize(
        tester,
        appScope(
          initialLocation: '/library/settings',
          extraOverrides: <Override>[
            settingsStoreProvider.overrideWithValue(store),
          ],
        ),
        size: kDesktop,
      );

      expect(switchValue(tester, 'Shuffle'), isFalse);
      expect(switchValue(tester, 'Autoplay'), isTrue);

      await tester.tap(find.widgetWithText(SwitchListTile, 'Shuffle'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SwitchListTile, 'Autoplay'));
      await tester.pumpAndSettle();

      // The screen reflects the player's real state...
      expect(switchValue(tester, 'Shuffle'), isTrue);
      expect(switchValue(tester, 'Autoplay'), isFalse);
      // ...and both went to the store the app loads from on the next launch.
      final AppSettings stored = await store.load();
      expect(stored.shuffle, isTrue);
      expect(stored.autoplay, isFalse);
    });

    testWidgets('the account names the session, never a navigation label', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/library/settings'),
        size: kDesktop,
      );

      await scrollSettingsTo(tester, find.text('Signed in as'));

      // The recorded session's own name...
      expect(find.text('Test Account'), findsOneWidget);
      // ...and never a label the service uses for its own chrome. (The nav rail
      // has a "Home" item on desktop, so this is scoped to the page.)
      expect(
        find.descendant(
          of: find.byType(SettingsScreen),
          matching: find.text('Home'),
        ),
        findsNothing,
      );
    });

    testWidgets('an account with no name falls back to the real handle', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(
          initialLocation: '/library/settings',
          repository: testRepository(
            responses: <String, http.Response>{
              // What the sidecar sends when the service states one of its own
              // chrome labels as the account name: no name, a real handle.
              '/account': jsonOk(
                '{"accountName":null,"channelHandle":"@someone",'
                '"accountPhotoUrl":null}',
              ),
            },
          ),
        ),
        size: kDesktop,
      );

      await scrollSettingsTo(tester, find.text('Signed in as'));
      expect(find.text('@someone'), findsOneWidget);
      expect(find.text('Your account'), findsNothing);
    });

    testWidgets('an account with nothing real to name says so', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(
          initialLocation: '/library/settings',
          repository: testRepository(
            responses: <String, http.Response>{
              '/account': jsonOk(
                '{"accountName":null,"channelHandle":null,'
                '"accountPhotoUrl":null}',
              ),
            },
          ),
        ),
        size: kDesktop,
      );

      await scrollSettingsTo(tester, find.text('Signed in as'));
      expect(find.text('Your account'), findsOneWidget);
    });

    testWidgets('the notes, rows and buttons share one content column', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/library/settings'),
        size: kDesktop,
      );

      final Rect screen = tester.getRect(find.byType(SettingsScreen));
      final double columnLeft =
          tester.getRect(find.text('Reduce transparency')).left;

      // The longest note wraps, so its box really is the content column: it
      // starts where the row title starts, and the margins on both sides match.
      await scrollSettingsTo(
        tester,
        find.textContaining('Your YouTube Music session is kept'),
      );
      final Rect note = tester.getRect(
        find.textContaining('Your YouTube Music session is kept'),
      );
      expect(note.left, closeTo(columnLeft, 0.5),
          reason: 'a note starts where a row title starts');
      expect(
        note.left - screen.left,
        closeTo(screen.right - note.right, 0.5),
        reason: 'the right margin matches the left',
      );

      // The Reset button sits on that same left edge, not centered.
      await scrollSettingsTo(
        tester,
        find.widgetWithText(PillButton, 'Reset preferences'),
      );
      expect(
        tester
            .getRect(find.widgetWithText(PillButton, 'Reset preferences'))
            .left,
        closeTo(columnLeft, 0.5),
      );
    });

    testWidgets('the header is pinned, opaque, and above the scrolling list', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/library/settings'),
        size: kDesktop,
      );

      final Finder header = find.byType(ScreenHeader);
      expect(header, findsOneWidget);
      // It is not inside the scroll view, so it stays put while the page moves.
      expect(
        find.ancestor(of: header, matching: find.byType(Scrollable)),
        findsNothing,
      );
      // And it paints the page background rather than leaving a hole.
      final Iterable<DecoratedBox> ancestors = tester.widgetList<DecoratedBox>(
        find.ancestor(of: header, matching: find.byType(DecoratedBox)),
      );
      expect(
        ancestors.any(
          (DecoratedBox box) =>
              box.decoration is BoxDecoration &&
              (box.decoration as BoxDecoration).color == Tokens.bg,
        ),
        isTrue,
        reason: 'the header has an opaque backdrop',
      );
    });

    testWidgets('Sign out is a sign-out action, on the page content column', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/library/settings'),
        size: kDesktop,
      );

      await scrollSettingsTo(tester, find.text('Signed in as'));
      final double columnLeft =
          tester.getRect(find.text('Signed in as')).left;
      await scrollSettingsTo(tester, find.text('Sign out'));

      expect(find.byIcon(AppIcons.signOut), findsOneWidget);
      expect(find.byIcon(AppIcons.close), findsNothing,
          reason: 'a close glyph is not a sign-out action');
      // The button box starts on the page's content column, so it reads as a
      // left-aligned action rather than a centered one.
      expect(
        tester.getRect(find.widgetWithText(PillButton, 'Sign out')).left,
        closeTo(columnLeft, 0.5),
      );
    });

    testWidgets('Reset preferences asks first, and only then resets', (
      WidgetTester tester,
    ) async {
      final InMemorySettingsStore store = InMemorySettingsStore();
      await pumpAtSize(
        tester,
        appScope(
          initialLocation: '/library/settings',
          extraOverrides: <Override>[
            settingsStoreProvider.overrideWithValue(store),
          ],
        ),
        size: kDesktop,
      );

      await tester.tap(find.widgetWithText(SwitchListTile, 'Reduce transparency'));
      await tester.pumpAndSettle();
      expect(switchValue(tester, 'Reduce transparency'), isTrue);
      expect((await store.load()).reduceTransparency, isTrue);

      final Finder reset = find.widgetWithText(PillButton, 'Reset preferences');
      await scrollSettingsTo(tester, reset);
      await tester.tap(reset);
      await tester.pumpAndSettle();

      // A destructive action needs a deliberate second step: the dialog is
      // asked for, and Cancel really cancels.
      expect(find.text('Reset preferences?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Reset preferences?'), findsNothing);
      expect((await store.load()).reduceTransparency, isTrue,
          reason: 'Cancel must not reset anything');

      // Confirming is the only path that resets, and it writes through.
      await tester.tap(reset);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset'));
      await tester.pumpAndSettle();
      expect((await store.load()).reduceTransparency, isFalse);

      // ...and the switch the user set really is back off.
      await scrollSettingsTo(
        tester,
        find.text('Reduce transparency'),
        dy: 300,
      );
      expect(switchValue(tester, 'Reduce transparency'), isFalse);
    });
  });

  group('equalizer', () {
    /// Every preset chip on screen, in the order they are laid out.
    List<Rect> presetChips(WidgetTester tester) => <Rect>[
      for (final EqualizerPreset preset in equalizerPresets)
        tester.getRect(find.widgetWithText(PillButton, preset.name)),
    ];

    testWidgets('presets are wrapped, left-aligned chips with a selected state',
        (WidgetTester tester) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/now-playing/equalizer'),
        size: kPhone,
      );

      final List<Rect> chips = presetChips(tester);
      final double leftMost =
          chips.map((Rect chip) => chip.left).reduce((double a, double b) =>
              a < b ? a : b);

      // A chip row, not full-width buttons: every chip is narrower than the
      // page and the row starts at the left edge.
      for (final Rect chip in chips) {
        expect(chip.width, lessThan(kPhone.width / 2));
      }
      expect(chips.first.left, closeTo(leftMost, 0.5));
      // It really wraps on a phone, and the second run starts on the same edge.
      final Set<double> rows = chips.map((Rect chip) => chip.top).toSet();
      expect(rows.length, greaterThan(1));
      expect(
        chips.where((Rect chip) => chip.left == leftMost).length,
        greaterThan(1),
      );

      // The selected preset is stated to assistive technology as well as
      // painted, and it is the chip the user actually chose.
      bool chipIsSelected(String label) => tester
          .widgetList<Semantics>(
            find.ancestor(
              of: find.text(label),
              matching: find.byType(Semantics),
            ),
          )
          .any((Semantics node) => node.properties.selected == true);
      int activeChips() => tester
          .widgetList<PillButton>(find.byType(PillButton))
          .where((PillButton chip) => chip.isActive)
          .length;

      // Off and flat to begin with: no preset is the selected one.
      expect(activeChips(), 0);
      expect(chipIsSelected('Flat'), isFalse);

      await tester.tap(find.text('Bass boost'));
      await tester.pumpAndSettle();

      expect(chipIsSelected('Bass boost'), isTrue);
      expect(chipIsSelected('Flat'), isFalse);
      expect(activeChips(), 1);
      expect(
        tester
            .widget<PillButton>(find.widgetWithText(PillButton, 'Bass boost'))
            .isActive,
        isTrue,
      );
    });

    testWidgets('every band states its gain in dB and the range it moves over',
        (WidgetTester tester) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/now-playing/equalizer'),
        size: kPhone,
      );

      expect(find.text('±${equalizerMaxGainDb.round()} dB per band'),
          findsOneWidget);

      // Flat by default: every band reads "0 dB" — a unit and a value, not a
      // bare integer that could be anything.
      expect(
        find.text('0 dB'),
        findsNWidgets(equalizerBandFrequenciesHz.length),
      );
      for (final int hz in equalizerBandFrequenciesHz) {
        final String label = hz >= 1000 ? '${hz ~/ 1000}k' : '$hz';
        expect(find.text(label), findsOneWidget, reason: '$hz Hz label');
      }

      // Selecting a preset moves the readouts, still in dB — one readout per
      // band, matching that preset's own gains.
      final EqualizerPreset bass = equalizerPresets
          .firstWhere((EqualizerPreset preset) => preset.name == 'Bass boost');
      final List<String> expected = <String>[
        for (final double gain in bass.gains)
          '${gain.round() > 0 ? '+' : ''}${gain.round()} dB',
      ];

      await tester.tap(find.text('Bass boost'));
      await tester.pumpAndSettle();

      for (final String label in expected.toSet()) {
        expect(
          find.text(label),
          findsNWidgets(expected.where((String l) => l == label).length),
          reason: label,
        );
      }
      expect(find.text('+9 dB'), findsOneWidget);
    });
  });

  group('selection reaches the player', () {
    testWidgets('tapping a search result plays it and opens the mini player', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/search'),
        size: kPhone,
      );

      await tester.enterText(find.byType(TextField), 'thriller');
      await settleSearch(tester);

      final MediaRow firstSong = tester.widget<MediaRow>(
        find.byType(MediaRow).first,
      );
      await tester.tap(find.byType(MediaRow).first);
      await tester.pumpAndSettle();

      expect(find.byType(MiniPlayer), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(MiniPlayer),
          matching: find.text(firstSong.item.title),
        ),
        findsOneWidget,
      );
    });
  });
}
