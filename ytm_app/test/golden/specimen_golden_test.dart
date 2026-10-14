import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ytm_app/theme/app_theme.dart';
import 'package:ytm_app/theme/tokens.dart';
import 'package:ytm_app/ui/specimen.dart';

import '../support/harness.dart';

/// The Phase 2 design-system catalogue. It stays mounted at `/dev` so the
/// primitives remain reviewable, separately from the product screens.
void main() {
  setUpAll(loadAppFonts);

  Widget catalogue() {
    return ProviderScope(
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark,
        themeMode: ThemeMode.dark,
        home: const Scaffold(
          backgroundColor: Tokens.bg,
          body: SafeArea(child: SpecimenBoard()),
        ),
      ),
    );
  }

  testWidgets('catalogue — phone 390x844', (WidgetTester tester) async {
    await pumpAtSize(tester, catalogue(), size: kPhone);
    await expectLater(
      find.byType(SpecimenBoard),
      matchesGoldenFile('goldens/specimen_phone_390x844.png'),
    );
  });

  testWidgets('catalogue — tablet 800x1280', (WidgetTester tester) async {
    await pumpAtSize(tester, catalogue(), size: kTablet);
    await expectLater(
      find.byType(SpecimenBoard),
      matchesGoldenFile('goldens/specimen_tablet_800x1280.png'),
    );
  });

  testWidgets('catalogue — desktop 1280x800', (WidgetTester tester) async {
    await pumpAtSize(tester, catalogue(), size: kDesktop);
    await expectLater(
      find.byType(SpecimenBoard),
      matchesGoldenFile('goldens/specimen_desktop_1280x800.png'),
    );
  });

  testWidgets('catalogue — desktop 1280x800 at text scale 1.3',
      (WidgetTester tester) async {
    await pumpAtSize(
      tester,
      catalogue(),
      size: kDesktop,
      textScale: kAccessibleTextScale,
    );
    await expectLater(
      find.byType(SpecimenBoard),
      matchesGoldenFile('goldens/specimen_desktop_1280x800_scale1_3.png'),
    );
  });
}
