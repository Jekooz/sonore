import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ytm_app/theme/icons.dart';
import 'package:ytm_app/ui/media_rows.dart';

import '../support/harness.dart';

/// The Phase 4 product screens against the recorded sidecar payloads.
///
/// These capture what the new data-backed destinations actually render — real
/// rails, real grouped search results, a real Library and a real collection
/// page — so a visual regression in the screens shows up here rather than only
/// in the shell, which sees them from a distance.
void main() {
  setUpAll(loadAppFonts);

  testWidgets('search results — phone 390x844', (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/search'),
      size: kPhone,
    );

    await tester.enterText(find.byType(TextField), 'thriller');
    // Waits out the controller's 300 ms debounce, then the request it issues.
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/product_search_results_phone_390x844.png'),
    );
  });

  testWidgets('library songs — desktop 1280x800', (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/library'),
      size: kDesktop,
    );

    await tester.tap(find.text('Songs').first);
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/product_library_songs_desktop_1280x800.png'),
    );
  });

  testWidgets('album page — desktop 1280x800', (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/library/collection/album/MPREb_test'),
      size: kDesktop,
    );

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/product_album_desktop_1280x800.png'),
    );
  });

  testWidgets('song context menu — desktop 1280x800', (
    WidgetTester tester,
  ) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/library'),
      size: kDesktop,
    );

    await tester.tap(find.text('Songs').first);
    await tester.pumpAndSettle();
    // Scoped to the row: the nav rail's Settings action shares this glyph.
    await tester.tap(
      find.descendant(
        of: find.byType(MediaRow).first,
        matching: find.byIcon(AppIcons.dotsThree),
      ),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/product_context_menu_desktop_1280x800.png'),
    );
  });
}
