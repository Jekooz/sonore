import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:ytm_app/audio/playback_controller.dart';
import 'package:ytm_app/audio/playback_state.dart';
import 'package:ytm_app/audio/track.dart';
import 'package:ytm_app/core/app_settings.dart';
import 'package:ytm_app/features/now_playing/queue_panel.dart';
import 'package:ytm_app/features/queue/queue_screen.dart';
import 'package:ytm_app/features/shell/now_playing_bar.dart';
import 'package:ytm_app/theme/icons.dart';
import 'package:ytm_app/ui/context_menu.dart';

import 'support/harness.dart';

/// The Queue screen against the real controller and the recorded sidecar.
///
/// Every assertion here is about what the queue *does*: the order the controller
/// holds, the track that would play next, the persisted autoplay mode. The
/// fixture queue is the app's own test queue; nothing is stubbed.

/// The live container the pumped app is running on, read from the widget tree
/// so assertions are about the same controller the screen is bound to.
ProviderContainer containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(QueueScreen)));

PlaybackState stateOf(WidgetTester tester) =>
    containerOf(tester).read(playbackProvider);

/// The queue order the controller holds, as ids.
List<String> orderOf(WidgetTester tester) => stateOf(tester)
    .queue
    .map((Track track) => track.id)
    .toList(growable: false);

Future<void> pumpQueue(
  WidgetTester tester, {
  Size size = kDesktop,
  int queueIndex = 0,
  List<Track>? queue,
  List<Override> extraOverrides = const <Override>[],
}) async {
  await pumpAtSize(
    tester,
    appScope(
      initialLocation: '/now-playing/queue',
      queue: queue ?? testQueue(),
      queueIndex: queueIndex,
      extraOverrides: extraOverrides,
    ),
    size: size,
  );
}

void main() {
  testWidgets('an empty queue says so instead of showing an empty list',
      (WidgetTester tester) async {
    await pumpQueue(tester, queue: const <Track>[]);

    expect(find.text('Nothing is queued.'), findsOneWidget);
    expect(find.text('Clear queue'), findsNothing);
  });

  testWidgets('the current track is marked and the rest are listed',
      (WidgetTester tester) async {
    await pumpQueue(tester);

    expect(find.byType(QueueScreen), findsOneWidget);
    // The mini player persists on the queue screen now, so the playing title
    // also appears in the bar; scope this expectation to the screen itself.
    expect(
      find.descendant(
        of: find.byType(QueueScreen),
        matching: find.text('Falling For You'),
      ),
      findsOneWidget,
    );
    expect(find.text('Now playing'), findsOneWidget);
    expect(find.text('Next up · 2'), findsOneWidget);
    expect(find.text('Midnight Drive'), findsOneWidget);
    expect(find.text('Paper Boats'), findsOneWidget);
  });

  testWidgets('tapping an upcoming row plays it, and the shell follows',
      (WidgetTester tester) async {
    await pumpQueue(tester);

    await tester.tap(find.text('Paper Boats'));
    await tester.pumpAndSettle();
    expect(stateOf(tester).current!.id, 'c');

    // §F: "Queue changes must be reflected in the Now Playing bar and Now Playing
    // immediately." The shell hides the Now Playing bar while Now Playing's branch
    // is on screen, so both halves are checked where each is visible: the Now
    // Playing title here, the Now Playing bar on a normal destination.
    await tester.tap(find.byTooltip('Back to Now Playing'));
    await tester.pumpAndSettle();
    expect(find.text('Paper Boats'), findsWidgets);

    await tester.tap(find.text('Home').first);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(NowPlayingBar),
        matching: find.text('Paper Boats'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the move buttons reorder the real queue',
      (WidgetTester tester) async {
    await pumpQueue(tester);
    expect(orderOf(tester), <String>['a', 'b', 'c']);

    // The first upcoming row is Midnight Drive: move it down one place.
    await tester.tap(find.byTooltip('Move Midnight Drive down'));
    await tester.pumpAndSettle();

    expect(orderOf(tester), <String>['a', 'c', 'b']);

    // And back up again.
    await tester.tap(find.byTooltip('Move Midnight Drive up'));
    await tester.pumpAndSettle();

    expect(orderOf(tester), <String>['a', 'b', 'c']);
  });

  testWidgets('the impossible move direction is not offered',
      (WidgetTester tester) async {
    await pumpQueue(tester);

    // The first upcoming row has nothing above it, the last has nothing below.
    expect(find.byTooltip('Move Midnight Drive up'), findsNothing);
    expect(find.byTooltip('Move Paper Boats down'), findsNothing);
    expect(find.byTooltip('Move Midnight Drive down'), findsOneWidget);
    expect(find.byTooltip('Move Paper Boats up'), findsOneWidget);
  });

  testWidgets('a drag handle reorders the queue', (WidgetTester tester) async {
    await pumpQueue(tester);
    expect(orderOf(tester), <String>['a', 'b', 'c']);

    // A timed drag, not a single jump: the reorder animation only commits
    // after the pointer has actually travelled past the next row.
    await tester.timedDrag(
      find.byIcon(AppIcons.dotsThreeVertical).first,
      const Offset(0, 90),
      const Duration(milliseconds: 600),
    );
    await tester.pumpAndSettle();

    expect(orderOf(tester), <String>['a', 'c', 'b']);
  });

  testWidgets('the row menu reuses the standard actions plus queue moves',
      (WidgetTester tester) async {
    await pumpQueue(tester);

    await tester.tap(find.byType(ContextMenuButton).first);
    await tester.pumpAndSettle();

    expect(find.text('Play now'), findsOneWidget);
    expect(find.text('Play next'), findsOneWidget);
    expect(find.text('Add to queue'), findsOneWidget);
    expect(find.text('Copy link'), findsOneWidget);
    expect(find.text('Move up'), findsOneWidget);
    expect(find.text('Move down'), findsOneWidget);
    expect(find.text('Remove from queue'), findsOneWidget);
  });

  testWidgets('Remove from queue takes the row out of the queue',
      (WidgetTester tester) async {
    await pumpQueue(tester);

    await tester.tap(find.byType(ContextMenuButton).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from queue'));
    await tester.pumpAndSettle();

    expect(orderOf(tester), <String>['a', 'c']);
    expect(find.text('Midnight Drive'), findsNothing);
  });

  testWidgets('clearing the queue asks first, and Cancel really cancels',
      (WidgetTester tester) async {
    await pumpQueue(tester);

    await tester.tap(find.text('Clear queue'));
    await tester.pumpAndSettle();
    expect(find.text('Clear the queue?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(orderOf(tester), <String>['a', 'b', 'c']);

    await tester.tap(find.text('Clear queue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();

    expect(stateOf(tester).hasTrack, isFalse);
    expect(find.text('Nothing is queued.'), findsOneWidget);
  });

  testWidgets('the autoplay switch drives the persisted mode',
      (WidgetTester tester) async {
    final InMemorySettingsStore store = InMemorySettingsStore();
    await pumpQueue(
      tester,
      extraOverrides: <Override>[
        settingsStoreProvider.overrideWithValue(store),
      ],
    );

    final SwitchListTile autoplay = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Autoplay'),
    );
    expect(autoplay.value, isTrue);

    await tester.tap(find.widgetWithText(SwitchListTile, 'Autoplay'));
    await tester.pumpAndSettle();

    expect(stateOf(tester).autoplay, isFalse);
    expect((await store.load()).autoplay, isFalse);
  });

  testWidgets('a shuffled queue says that its order is the play order',
      (WidgetTester tester) async {
    await pumpQueue(tester);
    expect(find.textContaining('Shuffle is on'), findsNothing);

    // Shuffle is toggled from the transport; the queue screen reports it, and
    // the note is honest about what the service does and does not expose.
    containerOf(tester).read(playbackProvider.notifier).setShuffle(true);
    await tester.pumpAndSettle();

    expect(find.textContaining('Shuffle is on'), findsOneWidget);
  });

  testWidgets('the queue panel links on to the full queue screen',
      (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/now-playing', queue: testQueue()),
      size: kPhone,
    );

    expect(find.byType(QueuePanel), findsNothing);

    // Open the on-demand panel, then travel on to the editing screen.
    await tester.tap(find.bySemanticsLabel('Queue'));
    await tester.pumpAndSettle();
    expect(find.byType(QueuePanel), findsOneWidget);

    await tester.tap(find.text('Open full queue'));
    await tester.pumpAndSettle();

    expect(find.byType(QueueScreen), findsOneWidget);
    expect(find.text('Next up · 2'), findsOneWidget);
  });
}
