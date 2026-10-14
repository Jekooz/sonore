import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ytm_app/features/library/library_screen.dart';
import 'package:ytm_app/features/now_playing/queue_carousel.dart';
import 'package:ytm_app/features/now_playing/queue_panel.dart';
import 'package:ytm_app/theme/icons.dart';
import 'package:ytm_app/ui/seek_bar.dart';

import 'support/harness.dart';

void main() {
  setUpAll(loadAppFonts);

  testWidgets('empty state is one sentence plus one real action',
      (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/now-playing'),
      size: kPhone,
    );

    expect(find.text('Nothing is playing yet.'), findsOneWidget);

    await tester.tap(find.text('Browse library'));
    await tester.pumpAndSettle();

    // The action really navigates: the Library destination is now on screen.
    expect(find.byType(LibraryScreen), findsOneWidget);
  });

  testWidgets('shows the current track and its artist and album',
      (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/now-playing', queue: testQueue()),
      size: kPhone,
    );

    expect(find.text('Falling For You'), findsOneWidget);
    expect(find.text('Nova · Nightfall'), findsOneWidget);
  });

  testWidgets('play/pause drives the real playback state',
      (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/now-playing', queue: testQueue()),
      size: kPhone,
    );

    expect(find.byIcon(AppIcons.pauseFill), findsOneWidget);

    await tester.tap(find.byIcon(AppIcons.pauseFill));
    await tester.pumpAndSettle();

    expect(find.byIcon(AppIcons.playFill), findsOneWidget);
    expect(find.byIcon(AppIcons.pauseFill), findsNothing);
  });

  testWidgets('next advances the shared queue', (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/now-playing', queue: testQueue()),
      size: kPhone,
    );

    await tester.tap(find.byIcon(AppIcons.skipForward));
    await tester.pumpAndSettle();

    expect(find.text('Midnight Drive'), findsOneWidget);
    expect(find.text('Aurora Lane · Static'), findsOneWidget);
  });

  testWidgets('previous on a barely-started track steps back',
      (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(
        initialLocation: '/now-playing',
        queue: testQueue(),
        queueIndex: 1,
        queuePosition: const Duration(seconds: 1),
      ),
      size: kPhone,
    );

    await tester.tap(find.byIcon(AppIcons.skipBack));
    await tester.pumpAndSettle();

    expect(find.text('Falling For You'), findsOneWidget);
  });

  testWidgets('the like action toggles and shows the accent',
      (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/now-playing', queue: testQueue()),
      size: kPhone,
    );

    expect(find.byIcon(AppIcons.heart), findsOneWidget);
    await tester.tap(find.byIcon(AppIcons.heart));
    await tester.pumpAndSettle();
    expect(find.byIcon(AppIcons.heartFill), findsOneWidget);
  });

  testWidgets('seeking through the bar commits to the controller',
      (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/now-playing', queue: testQueue()),
      size: kDesktop,
    );

    final Rect rect = tester.getRect(find.byType(SeekBar));
    await tester.tapAt(Offset(rect.left + rect.width * 0.5, rect.center.dy));
    await tester.pumpAndSettle();

    final SeekBar bar = tester.widget<SeekBar>(find.byType(SeekBar));
    // Half of 3:58 is 1:59.
    expect(bar.position.inSeconds, closeTo(119, 2));
    expect(bar.duration, const Duration(minutes: 3, seconds: 58));
  });

  testWidgets('desktop shows the queue panel, compact shows the carousel',
      (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/now-playing', queue: testQueue()),
      size: kDesktop,
    );

    expect(find.byType(QueuePanel), findsOneWidget);
    expect(find.text('Up Next'), findsOneWidget);
    expect(find.byType(QueueCarousel), findsNothing);

    await pumpAtSize(
      tester,
      appScope(initialLocation: '/now-playing', queue: testQueue()),
      size: kPhone,
    );

    expect(find.byType(QueueCarousel), findsOneWidget);
    expect(find.byType(QueuePanel), findsNothing);
  });

  testWidgets('the queue action hides and shows the panel on desktop',
      (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/now-playing', queue: testQueue()),
      size: kDesktop,
    );

    expect(find.byType(QueuePanel), findsOneWidget);

    await tester.tap(find.text('Queue'));
    await tester.pumpAndSettle();
    expect(find.byType(QueuePanel), findsNothing);

    await tester.tap(find.text('Queue'));
    await tester.pumpAndSettle();
    expect(find.byType(QueuePanel), findsOneWidget);
  });

  testWidgets('an engine error shows one sentence and Retry, with no red',
      (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(
        initialLocation: '/now-playing',
        queue: testQueue(),
        queueError: 'This track could not be streamed.',
      ),
      size: kPhone,
    );

    expect(find.text('This track could not be streamed.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('This track could not be streamed.'), findsNothing);
  });
}
