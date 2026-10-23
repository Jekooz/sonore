import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ytm_app/core/app_identity.dart';
import 'package:ytm_app/features/shell/window_title_bar.dart';

import '../support/harness.dart';

/// The shell itself: navigation, content area and the persistent Now Playing bar, on
/// the real routed app.
void main() {
  setUpAll(loadAppFonts);

  testWidgets('home — phone 390x844', (WidgetTester tester) async {
    await pumpAtSize(tester, appScope(), size: kPhone);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/shell_home_phone_390x844.png'),
    );
  });

  testWidgets('home — desktop 1280x800', (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(titleBar: const WindowTitleBar(title: appName)),
      size: kDesktop,
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/shell_home_desktop_1280x800.png'),
    );
  });

  testWidgets('library with the Now Playing bar — tablet 800x1280',
      (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/library', queue: testQueue()),
      size: kTablet,
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/shell_library_tablet_800x1280.png'),
    );
  });

  testWidgets('library with the mini player — phone 390x844',
      (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/library', queue: testQueue()),
      size: kPhone,
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/shell_library_mini_phone_390x844.png'),
    );
  });

  testWidgets('now playing empty inside the shell — phone 390x844',
      (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/now-playing'),
      size: kPhone,
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/shell_now_playing_empty_phone_390x844.png'),
    );
  });
}
