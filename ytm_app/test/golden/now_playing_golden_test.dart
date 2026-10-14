import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ytm_app/features/shell/window_title_bar.dart';

import '../support/harness.dart';

/// Now Playing on the real routed app, driven through the production playback
/// controller. The queue is a test fixture — the shipped app has no audio engine
/// yet, so this screen renders its empty state there.
///
/// Artwork renders as the designed no-artwork placeholder because goldens must
/// not fetch images; the ambient wash is the artwork-derived decoration and is
/// rendered from a fixed palette fixture.
void main() {
  setUpAll(loadAppFonts);

  testWidgets('now playing — phone 390x844', (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/now-playing', queue: testQueue()),
      size: kPhone,
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/now_playing_phone_390x844.png'),
    );
  });

  testWidgets('now playing — tablet 800x1280', (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/now-playing', queue: testQueue()),
      size: kTablet,
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/now_playing_tablet_800x1280.png'),
    );
  });

  testWidgets('now playing — desktop 1280x800', (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(
        initialLocation: '/now-playing',
        queue: testQueue(),
        titleBar: const WindowTitleBar(title: 'YT Music Client'),
      ),
      size: kDesktop,
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/now_playing_desktop_1280x800.png'),
    );
  });

  testWidgets('now playing — desktop 1280x800 at text scale 1.3', (
    WidgetTester tester,
  ) async {
    await pumpAtSize(
      tester,
      appScope(
        initialLocation: '/now-playing',
        queue: testQueue(),
        titleBar: const WindowTitleBar(title: 'YT Music Client'),
      ),
      size: kDesktop,
      textScale: kAccessibleTextScale,
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/now_playing_desktop_1280x800_scale1_3.png'),
    );
  });
}
