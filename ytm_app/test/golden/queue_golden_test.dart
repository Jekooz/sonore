import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// The Queue screen on the real routed app, through the production controller.
///
/// The screen is the one place where the queue is edited, so these capture the
/// two layouts it actually has: the wide one with the sidebar, and the phone.
void main() {
  setUpAll(loadAppFonts);

  testWidgets('queue — desktop 1280x800', (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/now-playing/queue', queue: testQueue()),
      size: kDesktop,
    );

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/queue_desktop_1280x800.png'),
    );
  });

  testWidgets('queue — phone 390x844', (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/now-playing/queue', queue: testQueue()),
      size: kPhone,
    );

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/queue_phone_390x844.png'),
    );
  });
}
