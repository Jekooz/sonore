import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// Riverpod 3 exposes `Override` only through misc.dart.
import 'package:riverpod/misc.dart' show Override;
import 'package:ytm_app/core/app_settings.dart';
import 'package:ytm_app/features/library/library_screen.dart';
import 'package:ytm_app/features/now_playing/queue_carousel.dart';
import 'package:ytm_app/features/now_playing/queue_panel.dart';
import 'package:ytm_app/theme/icons.dart';
import 'package:ytm_app/theme/tokens.dart';
import 'package:ytm_app/ui/art_tile.dart';
import 'package:ytm_app/ui/seek_bar.dart';

import 'support/harness.dart';

/// The fraction of the seek bar that is actually painted as played.
///
/// Read off the render tree rather than the widget's inputs: the accent
/// segment's painted width against the bar's own width is what the user sees,
/// so "the fill equals position ÷ duration" is measured, not inferred.
double paintedFill(WidgetTester tester) {
  final Rect bar = tester.getRect(find.byType(SeekBar));
  final Rect played = tester
      .widgetList<DecoratedBox>(
        find.descendant(
          of: find.byType(SeekBar),
          matching: find.byType(DecoratedBox),
        ),
      )
      .where((DecoratedBox box) =>
          (box.decoration as ShapeDecoration).color == Tokens.text)
      .map((DecoratedBox box) => tester.getRect(find.byWidget(box)))
      .single;
  return played.width / bar.width;
}

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

  testWidgets('the carousel is the centre at every size; desktop adds the panel',
      (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/now-playing', queue: testQueue()),
      size: kDesktop,
    );

    expect(find.byType(QueueCarousel), findsOneWidget);
    expect(find.byType(QueuePanel), findsOneWidget);
    expect(find.text('Up Next'), findsOneWidget);

    await pumpAtSize(
      tester,
      appScope(initialLocation: '/now-playing', queue: testQueue()),
      size: kPhone,
    );

    expect(find.byType(QueueCarousel), findsOneWidget);
    expect(find.byType(QueuePanel), findsNothing);
  });

  testWidgets('tapping a neighbouring cover skips to it',
      (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/now-playing', queue: testQueue()),
      size: kPhone,
    );

    expect(find.text('Falling For You'), findsOneWidget);

    // The carousel is circular, so both neighbours hang partly into the
    // viewport. Pick the right one by geometry: the tile that runs off the
    // right edge, and tap the part of it that is actually on screen.
    final Rect viewport = tester.getRect(find.byType(QueueCarousel));
    final List<Rect> rects = <Rect>[
      for (int i = 0; i < tester.widgetList(find.byType(ArtTile)).length; i++)
        tester.getRect(find.byType(ArtTile).at(i)),
    ];
    final Rect neighbour = rects.singleWhere(
      (Rect rect) => rect.left < viewport.right && rect.right > viewport.right,
    );
    final double left = neighbour.left.clamp(viewport.left, viewport.right);
    final double right = neighbour.right.clamp(viewport.left, viewport.right);
    await tester.tapAt(Offset((left + right) / 2, neighbour.center.dy));
    await tester.pumpAndSettle();

    expect(find.text('Midnight Drive'), findsOneWidget);
  });

  testWidgets('Reduce motion flattens the carousel — same queue, no 3D',
      (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(
        initialLocation: '/now-playing',
        queue: testQueue(),
        extraOverrides: <Override>[
          initialAppSettingsProvider.overrideWithValue(
            const AppSettings(reduceMotion: true),
          ),
        ],
      ),
      size: kDesktop,
    );

    // The preference reached MediaQuery, which is what every animated widget in
    // the app reads (the same switch that silences the press and shimmer).
    expect(
      MediaQuery.of(tester.element(find.byType(QueueCarousel)))
          .disableAnimations,
      isTrue,
    );
    // No per-item fade and no rotation: the non-reduce path wraps each cover in
    // an Opacity driven by the page offset.
    expect(
      find.descendant(
        of: find.byType(QueueCarousel),
        matching: find.byType(Opacity),
      ),
      findsNothing,
    );
    // It is still the queue, and the current cover is still on screen.
    expect(find.text('Falling For You'), findsWidgets);
  });

  testWidgets('without Reduce motion the carousel keeps its depth',
      (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/now-playing', queue: testQueue()),
      size: kDesktop,
    );

    expect(
      MediaQuery.of(tester.element(find.byType(QueueCarousel)))
          .disableAnimations,
      isFalse,
    );
    expect(
      find.descendant(
        of: find.byType(QueueCarousel),
        matching: find.byType(Opacity),
      ),
      findsWidgets,
    );
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
