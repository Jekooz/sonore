import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';
import '../support/recorded_sidecar.dart';

/// The four states every screen must have, plus sign-in.
///
/// Loading, empty and error are the real Now Playing screen driven into each
/// state through the production controller. Offline and sign-in are the real
/// Home screen driven through the production repository over a recorded sidecar
/// that refuses the connection and one that has no session, so both are the
/// states the app actually shows rather than a hand-composed stand-in.

void main() {
  setUpAll(loadAppFonts);

  testWidgets('loading — now playing phone 390x844',
      (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/now-playing', queueLoading: true),
      size: kPhone,
      // The skeleton shimmers forever, so settle would never finish.
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 300));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/state_loading_phone_390x844.png'),
    );
  });

  testWidgets('empty — now playing phone 390x844',
      (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/now-playing'),
      size: kPhone,
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/state_empty_phone_390x844.png'),
    );
  });

  testWidgets('error — now playing phone 390x844',
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
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/state_error_phone_390x844.png'),
    );
  });

  testWidgets('offline — home phone 390x844', (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/home', repository: offlineRepository()),
      size: kPhone,
    );

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/state_offline_phone_390x844.png'),
    );
  });

  testWidgets('signed out — home phone 390x844', (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/home', repository: signedOutRepository()),
      size: kPhone,
    );

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/state_signed_out_phone_390x844.png'),
    );
  });
}
