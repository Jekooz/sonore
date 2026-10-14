import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ytm_app/features/home/home_screen.dart';
import 'package:ytm_app/features/library/library_screen.dart';
import 'package:ytm_app/features/shell/mini_player.dart';
import 'package:ytm_app/features/shell/nav_bottom_bar.dart';
import 'package:ytm_app/features/shell/nav_rail.dart';

import 'support/harness.dart';

void main() {
  setUpAll(loadAppFonts);

  testWidgets('desktop shows the expanded sidebar and no bottom bar',
      (WidgetTester tester) async {
    await pumpAtSize(tester, appScope(), size: kDesktop);

    expect(find.byType(NavRail), findsOneWidget);
    expect(tester.widget<NavRail>(find.byType(NavRail)).expanded, isTrue);
    expect(find.byType(NavBottomBar), findsNothing);
  });

  testWidgets('tablet collapses the sidebar to a 72px icon rail',
      (WidgetTester tester) async {
    await pumpAtSize(tester, appScope(), size: kTablet);

    expect(find.byType(NavRail), findsOneWidget);
    expect(tester.widget<NavRail>(find.byType(NavRail)).expanded, isFalse);
    expect(find.byType(NavBottomBar), findsNothing);
  });

  testWidgets('phone shows the glass bottom bar and no sidebar',
      (WidgetTester tester) async {
    await pumpAtSize(tester, appScope(), size: kPhone);

    expect(find.byType(NavBottomBar), findsOneWidget);
    expect(find.byType(NavRail), findsNothing);
    // The bar is real glass, so a BackdropFilter is in the tree.
    expect(find.byType(BackdropFilter), findsWidgets);
  });

  testWidgets('selecting a destination changes the screen',
      (WidgetTester tester) async {
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

  testWidgets('the same navigation works from the desktop rail',
      (WidgetTester tester) async {
    await pumpAtSize(tester, appScope(), size: kDesktop);

    await tester.tap(find.text('Now Playing'));
    await tester.pumpAndSettle();

    expect(find.text('Nothing is playing yet.'), findsOneWidget);
  });

  testWidgets('the mini player stays hidden until a queue is loaded',
      (WidgetTester tester) async {
    await pumpAtSize(tester, appScope(), size: kPhone);
    expect(find.byType(MiniPlayer), findsNothing);
  });

  testWidgets('the mini player appears in the shell once a queue is loaded',
      (WidgetTester tester) async {
    await pumpAtSize(tester, appScope(queue: testQueue()), size: kPhone);

    expect(find.byType(MiniPlayer), findsOneWidget);
    expect(find.text('Falling For You'), findsOneWidget);
    expect(find.text('Nova'), findsOneWidget);
  });

  testWidgets('tapping the mini player opens Now Playing',
      (WidgetTester tester) async {
    await pumpAtSize(tester, appScope(queue: testQueue()), size: kPhone);

    await tester.tap(find.text('Falling For You'));
    await tester.pumpAndSettle();

    // Now Playing shows its own metadata block, so the title appears there
    // while the mini player has stepped aside.
    expect(find.byType(MiniPlayer), findsNothing);
    expect(find.text('Nova · Nightfall'), findsOneWidget);
  });

  testWidgets('the mini player steps aside on Now Playing',
      (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/now-playing', queue: testQueue()),
      size: kPhone,
    );

    expect(find.byType(MiniPlayer), findsNothing);
  });

  testWidgets('the mini player is a floating bar above content on desktop',
      (WidgetTester tester) async {
    await pumpAtSize(tester, appScope(queue: testQueue()), size: kDesktop);

    expect(find.byType(MiniPlayer), findsOneWidget);
    final Rect bar = tester.getRect(find.byType(MiniPlayer));
    final Rect window = tester.getRect(find.byType(Scaffold).first);
    // It floats at the bottom of the window rather than in a reserved row.
    expect(bar.bottom, lessThanOrEqualTo(window.bottom));
    expect(bar.width, greaterThan(kDesktop.width / 2));
  });
}
