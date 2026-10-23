import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// Riverpod 3 exposes `Override` only through `misc.dart`.
import 'package:riverpod/misc.dart' show Override;
import 'package:ytm_app/core/app_settings.dart';
import 'package:ytm_app/audio/track.dart';

import '../support/harness.dart';
import '../support/recorded_sidecar.dart';
import '../support/sample_artwork.dart' show kMulticolorFixtureUrl;

/// The visual audit capture: every audited screen at every audited width.
///
/// This renders *screenshots*, not test goldens: it exists so a UI pass can be
/// reviewed at 1920, 1280, 800 and phone widths with the same deterministic
/// seams the goldens use (no network, fixed palette, fake engine). Run it with
///
///     flutter test test/visual_audit/audit_shots_test.dart --update-goldens
///
/// and the PNGs land in test/visual_audit/goldens/, from where
/// `tool/audit_shots.ps1` copies them into proof/audit/ for review. Outside an
/// audit round the file contributes nothing: every test exits immediately
/// unless SONORE_VISUAL_AUDIT=1, so the default `flutter test` run is unchanged.
void main() {
  setUpAll(loadAppFonts);

  final bool run = Platform.environment['SONORE_VISUAL_AUDIT'] == '1';
  if (!run) {
    // Not an audit round: say so once and add no tests at all.
    return;
  }

  const List<(String, Size)> widths = <(String, Size)>[
    ('wide', Size(1920, 1080)),
    ('desktop', Size(1280, 800)),
    ('narrow', Size(800, 600)),
    ('phone', Size(390, 844)),
  ];

  for (final (String name, Size size) in widths) {
    testWidgets('home ${size.width}x${size.height}', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/home', queue: testQueue()),
        size: size,
      );
      await _capture(tester, 'home_$name');
    });

    testWidgets('search ${size.width}x${size.height}', (
      WidgetTester tester,
    ) async {
      final Widget app = appScope(
        initialLocation: '/search',
        queue: testQueue(),
      );
      await pumpAtSize(tester, app, size: size);
      await tester.enterText(find.byType(TextField), 'thriller');
      // Waits out the search debounce, then the request.
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      await _capture(tester, 'search_$name');
    });

    testWidgets('library ${size.width}x${size.height}', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/library', queue: testQueue()),
        size: size,
      );
      await _capture(tester, 'library_$name');
    });

    testWidgets('playlist ${size.width}x${size.height}', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(
          initialLocation: '/library/collection/album/MPREb_test',
          queue: testQueue(),
        ),
        size: size,
      );
      await _capture(tester, 'playlist_$name');
    });

    testWidgets('now-playing ${size.width}x${size.height}', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/now-playing', queue: testQueue()),
        size: size,
      );
      await _capture(tester, 'now_playing_$name');
    });

    testWidgets('equalizer ${size.width}x${size.height}', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/now-playing/equalizer', queue: testQueue()),
        size: size,
      );
      await _capture(tester, 'equalizer_$name');
    });

    testWidgets('settings ${size.width}x${size.height}', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/home/settings', queue: testQueue()),
        size: size,
      );
      await _capture(tester, 'settings_$name');
    });

    testWidgets('sign-in ${size.width}x${size.height}', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/home', repository: signedOutRepository()),
        size: size,
      );
      await _capture(tester, 'sign_in_$name');
    });

    testWidgets('reduce transparency ${size.width}x${size.height}', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(
          initialLocation: '/home',
          queue: testQueue(),
          extraOverrides: <Override>[
            initialAppSettingsProvider.overrideWithValue(
              const AppSettings(reduceTransparency: true),
            ),
          ],
        ),
        size: size,
      );
      await _capture(tester, 'reduce_transparency_$name');
    });
  }

  // The ambient palette is artwork-derived: these two captures pin a
  // multicolor fixture (the lagoon variant: blue, cyan and navy) as the
  // playing track so Home and Now Playing visibly carry more than one hue,
  // instead of a wash from a single dominant color.
  const List<Track> multicolorQueue = <Track>[
    Track(
      id: 'multicolor-fixture',
      title: 'Prism Riding Hood',
      artist: 'Aurora Lane',
      album: 'Spectra',
      duration: Duration(minutes: 3, seconds: 12),
      artworkUrl: kMulticolorFixtureUrl,
    ),
  ];

  testWidgets('home with the multicolor artwork fixture', (
    WidgetTester tester,
  ) async {
    await pumpAtSize(
      tester,
      appScope(initialLocation: '/home', queue: multicolorQueue),
      size: const Size(1280, 800),
    );
    await _capture(tester, 'home_multicolor_desktop');
  });

  for (final (String name, Size size) in <(String, Size)>[
    ('desktop', const Size(1280, 800)),
    ('narrow', const Size(800, 600)),
  ]) {
    testWidgets('now playing with the multicolor artwork fixture ($name)', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/now-playing', queue: multicolorQueue),
        size: size,
      );
      await _capture(tester, 'now_playing_multicolor_$name');
    });
  }
}

Future<void> _capture(WidgetTester tester, String name) async {
  final Size size = tester.view.physicalSize / tester.view.devicePixelRatio;
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile(
      'goldens/${name}_${size.width.toInt()}x${size.height.toInt()}.png',
    ),
  );
}
