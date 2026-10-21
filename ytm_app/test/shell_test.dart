import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// Riverpod 3 exposes `Override` only through misc.dart.
import 'package:riverpod/misc.dart' show Override;
import 'package:ytm_app/core/app_settings.dart';
import 'package:ytm_app/features/equalizer/equalizer_screen.dart';
import 'package:ytm_app/features/home/home_screen.dart';
import 'package:ytm_app/features/library/library_screen.dart';
import 'package:ytm_app/features/shell/nav_bottom_bar.dart';
import 'package:ytm_app/features/shell/nav_tab_bar.dart';
import 'package:ytm_app/features/shell/now_playing_bar.dart';
import 'package:ytm_app/routing/destinations.dart';
import 'package:ytm_app/theme/icons.dart';
import 'package:ytm_app/theme/tokens.dart';
import 'package:ytm_app/ui/glass_surface.dart';

import 'support/harness.dart';

/// Taps a destination inside the floating top tab bar.
///
/// Scoped to the bar on purpose: the Library page itself renders the word
/// "Library", so an unscoped text finder would be ambiguous once the reader is
/// already there.
Future<void> tapTab(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(of: find.byType(NavTabBar), matching: find.text(label)),
  );
  await tester.pumpAndSettle();
}

/// An icon finder scoped to the tab bar, so a glyph the page happens to reuse
/// (the search field's magnifier, the empty state's library button) cannot be
/// mistaken for a tab.
Finder tabIcon(IconData icon) =>
    find.descendant(of: find.byType(NavTabBar), matching: find.byIcon(icon));

void main() {
  setUpAll(loadAppFonts);

  testWidgets('desktop shows the floating top tab bar and no bottom bar', (
    WidgetTester tester,
  ) async {
    await pumpAtSize(tester, appScope(), size: kDesktop);

    expect(find.byType(NavTabBar), findsOneWidget);
    expect(find.byType(NavBottomBar), findsNothing);
    // It is real glass, so a BackdropFilter is in the tree.
    expect(
      find.descendant(
        of: find.byType(NavTabBar),
        matching: find.byType(BackdropFilter),
      ),
      findsOneWidget,
    );
  });

  testWidgets('tablet uses the same top tab bar, not a sidebar', (
    WidgetTester tester,
  ) async {
    await pumpAtSize(tester, appScope(), size: kTablet);

    expect(find.byType(NavTabBar), findsOneWidget);
    expect(find.byType(NavBottomBar), findsNothing);
  });

  testWidgets('phone keeps the compact bottom bar and has no top tab bar', (
    WidgetTester tester,
  ) async {
    await pumpAtSize(tester, appScope(), size: kPhone);

    expect(find.byType(NavBottomBar), findsOneWidget);
    expect(find.byType(NavTabBar), findsNothing);
    // The bar is real glass, so a BackdropFilter is in the tree.
    expect(find.byType(BackdropFilter), findsWidgets);
  });

  testWidgets('selecting a destination changes the screen', (
    WidgetTester tester,
  ) async {
    await pumpAtSize(tester, appScope(), size: kPhone);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.text('Good evening'), findsOneWidget);

    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();

    expect(find.byType(LibraryScreen), findsOneWidget);
    // The Library's own segmented control, over real segments.
    expect(find.text('Playlists'), findsOneWidget);
    expect(find.text('Good evening'), findsNothing);
  });

  testWidgets('the same navigation works from the top tab bar', (
    WidgetTester tester,
  ) async {
    await pumpAtSize(tester, appScope(), size: kDesktop);

    await tapTab(tester, 'Now Playing');

    expect(find.text('Nothing is playing yet.'), findsOneWidget);
  });

  testWidgets('each destination lights exactly its own tab', (
    WidgetTester tester,
  ) async {
    await pumpAtSize(tester, appScope(), size: kDesktop);

    // A tab is active when it wears its filled glyph, painted full-bright;
    // every other tab stays outlined and secondary.
    void expectOnlyActive(IconData filled) {
      expect(tabIcon(filled), findsOneWidget, reason: '${filled.codePoint}');
      expect(
        tester.widget<Icon>(tabIcon(filled)).color,
        Tokens.text,
        reason: 'the active tab is full-bright white',
      );
      for (final AppDestination destination in AppDestination.values) {
        if (destination.activeIcon == filled) continue;
        expect(tabIcon(destination.activeIcon), findsNothing);
        expect(tabIcon(destination.icon), findsOneWidget);
        expect(
          tester.widget<Icon>(tabIcon(destination.icon)).color,
          Tokens.textSecondary,
        );
      }
    }

    // Home is lit to begin with.
    expectOnlyActive(AppIcons.houseFill);

    await tapTab(tester, 'Search');
    expectOnlyActive(AppIcons.magnifyingGlassFill);

    await tapTab(tester, 'Library');
    expectOnlyActive(AppIcons.listBulletsFill);

    await tapTab(tester, 'Now Playing');
    expectOnlyActive(AppIcons.musicNotesFill);
  });

  testWidgets('the tab bar follows the route, not just the branch', (
    WidgetTester tester,
  ) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/now-playing', queue: testQueue()),
      size: kDesktop,
    );

    // On Now Playing the destination itself is the active tab.
    NavTabBar bar = tester.widget<NavTabBar>(find.byType(NavTabBar));
    expect(bar.currentIndex, AppDestination.nowPlaying.index);
    expect(bar.settingsActive, isFalse);
    expect(tabIcon(AppIcons.musicNotesFill), findsOneWidget);

    // The Equalizer is now a Settings-side page (the link lives there). On
    // top of Now Playing it must still light the Settings action, and Now
    // Playing must not stay lit.
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/now-playing/equalizer', queue: testQueue()),
      size: kDesktop,
    );

    expect(find.byType(EqualizerScreen), findsOneWidget);
    bar = tester.widget<NavTabBar>(find.byType(NavTabBar));
    expect(bar.settingsActive, isTrue);
    expect(bar.currentIndex, isNull);
    expect(tabIcon(AppIcons.musicNotesFill), findsNothing);
    expect(tabIcon(AppIcons.musicNotes), findsOneWidget);
    expect(
      tester
          .widget<Icon>(
            find.descendant(
              of: find.byType(NavTabBar),
              matching: find.byIcon(AppIcons.dotsThree),
            ),
          )
          .color,
      Tokens.text,
    );

    // Settings itself, opened from a different destination, behaves the same.
    await tester.tap(
      find.descendant(
        of: find.byType(NavTabBar),
        matching: find.byIcon(AppIcons.dotsThree),
      ),
    );
    await tester.pumpAndSettle();

    bar = tester.widget<NavTabBar>(find.byType(NavTabBar));
    expect(bar.settingsActive, isTrue);
    expect(bar.currentIndex, isNull);
  });

  testWidgets('the bottom bar follows the route too', (
    WidgetTester tester,
  ) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/library', queue: testQueue()),
      size: kPhone,
    );

    expect(find.byIcon(AppIcons.listBulletsFill), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byType(NavBottomBar),
        matching: find.byIcon(AppIcons.dotsThree),
      ),
    );
    await tester.pumpAndSettle();

    final NavBottomBar bar = tester.widget<NavBottomBar>(
      find.byType(NavBottomBar),
    );
    expect(bar.settingsActive, isTrue);
    expect(bar.currentIndex, isNull);
    expect(find.byIcon(AppIcons.listBulletsFill), findsNothing);
  });

  testWidgets('the Now Playing bar stays hidden until a queue is loaded', (
    WidgetTester tester,
  ) async {
    await pumpAtSize(tester, appScope(), size: kPhone);
    expect(find.byType(NowPlayingBar), findsNothing);
  });

  testWidgets(
    'the Now Playing bar appears in the shell once a queue is loaded',
    (WidgetTester tester) async {
      await pumpAtSize(tester, appScope(queue: testQueue()), size: kPhone);

      expect(find.byType(NowPlayingBar), findsOneWidget);
      expect(find.text('Falling For You'), findsOneWidget);
      expect(find.text('Nova'), findsOneWidget);
    },
  );

  testWidgets('tapping the Now Playing bar opens Now Playing', (
    WidgetTester tester,
  ) async {
    await pumpAtSize(tester, appScope(queue: testQueue()), size: kPhone);

    await tester.tap(find.text('Falling For You'));
    await tester.pumpAndSettle();

    // Now Playing shows its own metadata block, so the title appears there
    // while the docked bar has stepped aside.
    expect(find.byType(NowPlayingBar), findsNothing);
    expect(find.text('Nova · Nightfall'), findsOneWidget);
  });

  testWidgets('the Now Playing bar steps aside on Now Playing', (
    WidgetTester tester,
  ) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/now-playing', queue: testQueue()),
      size: kPhone,
    );

    expect(find.byType(NowPlayingBar), findsNothing);
  });

  testWidgets(
    'desktop docks the Now Playing bar flush with the window bottom',
    (WidgetTester tester) async {
      await pumpAtSize(tester, appScope(queue: testQueue()), size: kDesktop);

      expect(find.byType(NowPlayingBar), findsOneWidget);
      final Rect bar = tester.getRect(find.byType(NowPlayingBar));
      final Rect window = tester.getRect(find.byType(Scaffold).first);

      // Full window width and flush with the bottom edge: a docked bar, not a
      // centered pill with a gap under it.
      expect(bar.left, closeTo(window.left, 1));
      expect(bar.width, closeTo(window.width, 1));
      expect(bar.bottom, closeTo(window.bottom, 1));

      // The surface is explicitly docked, so it cannot paint the floating
      // shadow or specular streak.
      final GlassSurface surface = tester.widget<GlassSurface>(
        find.descendant(
          of: find.byType(NowPlayingBar),
          matching: find.byType(GlassSurface),
        ),
      );
      expect(surface.isFloating, isFalse);
      expect(surface.shape, Tokens.shapeAnchoredBar);
    },
  );

  testWidgets('phone docks the bar above the floating navigation menu', (
    WidgetTester tester,
  ) async {
    await pumpAtSize(tester, appScope(queue: testQueue()), size: kPhone);

    final Rect bar = tester.getRect(find.byType(NowPlayingBar));
    final Rect window = tester.getRect(find.byType(Scaffold).first);
    final Rect navPill = tester.getRect(
      find.descendant(
        of: find.byType(NavBottomBar),
        matching: find.byType(GlassSurface),
      ),
    );

    // The bar spans the content width...
    expect(bar.width, closeTo(window.width, 1));
    // ...sits above the navigation menu, not over it...
    expect(bar.bottom, lessThanOrEqualTo(navPill.top));
    // ...and the menu itself stays detached from the window edges.
    expect(navPill.left, greaterThan(window.left));
    expect(navPill.right, lessThan(window.right));
    expect(navPill.bottom, lessThan(window.bottom));
  });

  testWidgets('resizing the window reflows the bar without overlap', (
    WidgetTester tester,
  ) async {
    await pumpAtSize(tester, appScope(queue: testQueue()), size: kDesktop);

    tester.view.physicalSize = const Size(360, 640);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(NowPlayingBar), findsOneWidget);
    expect(find.byType(NavBottomBar), findsOneWidget);

    final Rect bar = tester.getRect(find.byType(NowPlayingBar));
    final Rect window = tester.getRect(find.byType(Scaffold).first);
    expect(bar.width, closeTo(window.width, 1));
    expect(bar.bottom, lessThan(window.bottom));
  });

  testWidgets('a narrow phone keeps the bar and its controls usable', (
    WidgetTester tester,
  ) async {
    await pumpAtSize(
      tester,
      appScope(queue: testQueue()),
      size: const Size(320, 640),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(NowPlayingBar), findsOneWidget);
    expect(find.byIcon(AppIcons.skipBack), findsOneWidget);
    expect(find.byIcon(AppIcons.skipForward), findsOneWidget);
  });

  testWidgets('every destination survives a 320 px phone', (
    WidgetTester tester,
  ) async {
    for (final String path in <String>[
      '/home',
      '/search',
      '/library',
      '/now-playing',
    ]) {
      await pumpAtSize(
        tester,
        appScope(initialLocation: path, queue: testQueue()),
        size: const Size(320, 640),
      );

      expect(tester.takeException(), isNull, reason: path);
    }
  });

  testWidgets('the bar survives the largest text scale', (
    WidgetTester tester,
  ) async {
    await pumpAtSize(
      tester,
      appScope(queue: testQueue()),
      size: kPhone,
      textScale: kAccessibleTextScale,
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(NowPlayingBar), findsOneWidget);
    expect(find.text('Falling For You'), findsOneWidget);
  });

  testWidgets(
    'Reduce transparency swaps the tab bar glass for a solid surface',
    (WidgetTester tester) async {
      await pumpAtSize(
        tester,
        appScope(
          extraOverrides: <Override>[
            initialAppSettingsProvider.overrideWithValue(
              const AppSettings(reduceTransparency: true),
            ),
          ],
        ),
        size: kDesktop,
      );

      expect(find.byType(NavTabBar), findsOneWidget);
      // The solid fallback is the whole point: no blur anywhere in the bar.
      expect(
        find.descendant(
          of: find.byType(NavTabBar),
          matching: find.byType(BackdropFilter),
        ),
        findsNothing,
      );
    },
  );
}
