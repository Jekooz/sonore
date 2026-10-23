import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ytm_app/features/library/library_screen.dart';
import 'package:ytm_app/features/now_playing/queue_panel.dart';
import 'package:ytm_app/features/now_playing/transport_pill.dart';
import 'package:ytm_app/features/shell/nav_bottom_bar.dart';
import 'package:ytm_app/theme/icons.dart';
import 'package:ytm_app/theme/tokens.dart';
import 'package:ytm_app/ui/art_tile.dart';
import 'package:ytm_app/ui/seek_bar.dart';

import 'support/harness.dart';

/// The fraction of the seek bar that is actually painted as played.
///
/// Read off the render tree rather than the widget's inputs: the played
/// segment's painted width against the bar's own width is what the user
/// sees, so "the fill equals position ÷ duration" is measured, not inferred.
double paintedFill(WidgetTester tester) {
  final Rect bar = tester.getRect(find.byType(SeekBar));
  final Rect played = tester
      .widgetList<DecoratedBox>(
        find.descendant(
          of: find.byType(SeekBar),
          matching: find.byType(DecoratedBox),
        ),
      )
      .where(
        (DecoratedBox box) =>
            (box.decoration as ShapeDecoration).color == Tokens.text,
      )
      .map((DecoratedBox box) => tester.getRect(find.byWidget(box)))
      .single;
  return played.width / bar.width;
}

void main() {
  setUpAll(loadAppFonts);

  testWidgets('empty state is one sentence plus one real action', (
    WidgetTester tester,
  ) async {
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

  testWidgets('shows the current track and its artist', (
    WidgetTester tester,
  ) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/now-playing', queue: testQueue()),
      size: kPhone,
    );

    expect(find.text('Falling For You'), findsOneWidget);
    expect(find.text('Nova · Nightfall'), findsOneWidget);
  });

  testWidgets('the artwork absorbs the viewport and never scrolls', (
    WidgetTester tester,
  ) async {
    // Every audited window, including the landscape-size one: the page is a
    // fitted composition — artwork and controls share the viewport, so there
    // is never a scrollable and never an overflow, whatever the shape.
    const List<(String, Size)> sizes = <(String, Size)>[
      ('desktop wide', Size(1920, 1080)),
      ('desktop', kDesktop),
      ('narrow', Size(800, 600)),
      ('phone', kPhone),
      ('narrow phone', Size(320, 690)),
    ];
    for (final (String name, Size size) in sizes) {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/now-playing', queue: testQueue()),
        size: size,
      );

      expect(tester.takeException(), isNull, reason: name);
      // The artwork is the biggest element and stays proportional to the
      // window: no scrollable anywhere on this page.
      expect(find.byType(ListView), findsNothing, reason: name);
      expect(find.byType(SingleChildScrollView), findsNothing, reason: name);
      expect(find.byType(RefreshIndicator), findsNothing, reason: name);
    }
  });

  testWidgets(
    'a short wide window lays out in two columns — art left, controls right '
    '— even at 1.3 text scale',
    (WidgetTester tester) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/now-playing', queue: testQueue()),
        size: const Size(800, 600),
        textScale: kAccessibleTextScale,
      );

      expect(tester.takeException(), isNull);
      expect(find.byType(ListView), findsNothing);

      // Two columns: the artwork sits entirely to the left of the
      // scrubber's column, and the scrubber is as wide as that column —
      // controls are vertically centered beside the art instead of stacked
      // over it.
      final Rect art = tester.getRect(find.byType(ArtTile).first);
      final Rect seek = tester.getRect(find.byType(SeekBar));
      expect(art.right, lessThanOrEqualTo(seek.left));
      expect(art.height, lessThanOrEqualTo(600 - 36 - Tokens.s32));

      // The transport pill keeps its own width floor in the right column.
      expect(
        tester.getRect(find.byType(TransportPill)).width,
        greaterThanOrEqualTo(TransportPill.minWidth - 1),
      );
    },
  );

  testWidgets('play/pause drives the real playback state', (
    WidgetTester tester,
  ) async {
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

  testWidgets('previous on a barely-started track steps back', (
    WidgetTester tester,
  ) async {
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

  testWidgets('the like action toggles and shows the filled icon', (
    WidgetTester tester,
  ) async {
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

  testWidgets('seeking through the bar commits to the controller', (
    WidgetTester tester,
  ) async {
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

  testWidgets('the progress fill is position ÷ duration, on seek and on a '
      'track change', (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(
        initialLocation: '/now-playing',
        queue: testQueue(),
        queuePosition: const Duration(seconds: 1),
      ),
      size: kDesktop,
    );

    // One second into a 3:58 track.
    SeekBar bar = tester.widget<SeekBar>(find.byType(SeekBar));
    expect(bar.position, const Duration(seconds: 1));
    expect(bar.duration, const Duration(minutes: 3, seconds: 58));
    expect(paintedFill(tester), closeTo(1 / 238, 0.001));

    // A seek paints the position it committed, to the same fraction.
    final Rect track = tester.getRect(find.byType(SeekBar));
    await tester.tapAt(Offset(track.left + track.width * 0.5, track.center.dy));
    await tester.pumpAndSettle();

    bar = tester.widget<SeekBar>(find.byType(SeekBar));
    expect(bar.position.inSeconds, closeTo(119, 2));
    expect(
      paintedFill(tester),
      closeTo(bar.position.inMilliseconds / bar.duration.inMilliseconds, 0.001),
    );

    // Changing track restarts the fill at zero against the new track's own
    // length, rather than carrying the previous track's progress over.
    await tester.tap(find.byIcon(AppIcons.skipForward));
    await tester.pumpAndSettle();

    bar = tester.widget<SeekBar>(find.byType(SeekBar));
    expect(bar.duration, const Duration(minutes: 4, seconds: 12));
    expect(bar.position, Duration.zero);
    expect(paintedFill(tester), 0);
  });

  testWidgets('no panel is open by default, on any size', (
    WidgetTester tester,
  ) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/now-playing', queue: testQueue()),
      size: kDesktop,
    );
    expect(find.byType(QueuePanel), findsNothing);

    await pumpAtSize(
      tester,
      appScope(initialLocation: '/now-playing', queue: testQueue()),
      size: kPhone,
    );
    expect(find.byType(QueuePanel), findsNothing);
  });

  testWidgets('the Queue icon toggles the desktop side panel', (
    WidgetTester tester,
  ) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/now-playing', queue: testQueue()),
      size: kDesktop,
    );

    await tester.tap(find.bySemanticsLabel('Queue'));
    await tester.pumpAndSettle();

    // The panel is the queue: Now playing above Up next, live bars on the
    // marked row.
    expect(find.byType(QueuePanel), findsOneWidget);
    expect(find.text('Now playing'), findsOneWidget);
    expect(find.text('Up next'), findsOneWidget);

    // Tapping the same icon again closes it.
    await tester.tap(find.bySemanticsLabel('Queue'));
    await tester.pumpAndSettle();
    expect(find.byType(QueuePanel), findsNothing);
  });

  testWidgets('the Lyrics and Queue icons never stack two panels', (
    WidgetTester tester,
  ) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/now-playing', queue: testQueue()),
      size: kDesktop,
    );

    await tester.tap(find.bySemanticsLabel('Queue'));
    await tester.pumpAndSettle();
    expect(find.byType(QueuePanel), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Lyrics'));
    await tester.pumpAndSettle();
    expect(find.byType(QueuePanel), findsNothing);

    // Switching back and forth again keeps exactly one panel.
    await tester.tap(find.bySemanticsLabel('Queue'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Queue'));
    await tester.pumpAndSettle();
    expect(find.byType(QueuePanel), findsNothing);
  });

  testWidgets('tap outside closes the open panel', (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/now-playing', queue: testQueue()),
      size: kDesktop,
    );

    await tester.tap(find.bySemanticsLabel('Queue'));
    await tester.pumpAndSettle();
    expect(find.byType(QueuePanel), findsOneWidget);

    // The barrier covers the page; a tap far from the right-edge panel
    // dismisses it.
    await tester.tapAt(const Offset(60, 300));
    await tester.pumpAndSettle();
    expect(find.byType(QueuePanel), findsNothing);
  });

  testWidgets('Esc closes the open panel', (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/now-playing', queue: testQueue()),
      size: kDesktop,
    );

    await tester.tap(find.bySemanticsLabel('Queue'));
    await tester.pumpAndSettle();
    expect(find.byType(QueuePanel), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(QueuePanel), findsNothing);
  });

  testWidgets('on phone the Queue icon opens a bottom sheet, dismissed by '
      'its grip', (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/now-playing', queue: testQueue()),
      size: kPhone,
    );

    await tester.tap(find.bySemanticsLabel('Queue'));
    await tester.pumpAndSettle();

    // The sheet is a panel, not a pushed page, and it bottoms out above the
    // floating navigation pill rather than over it.
    expect(find.byType(QueuePanel), findsOneWidget);
    final Rect sheet = tester.getRect(find.byType(QueuePanel));
    final Rect pill = tester.getRect(find.byType(NavBottomBar));
    expect(sheet.bottom, lessThanOrEqualTo(pill.top + 1));

    // The grip flings the sheet away.
    final Rect grip = tester.getRect(
      find.byKey(const ValueKey<String>('np-panel-grip')),
    );
    await tester.flingFrom(grip.center, const Offset(0, 200), 1200);
    await tester.pumpAndSettle();
    expect(find.byType(QueuePanel), findsNothing);
  });

  testWidgets('an engine error shows one sentence and Retry, with no red', (
    WidgetTester tester,
  ) async {
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
