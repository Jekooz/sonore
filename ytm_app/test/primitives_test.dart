import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ytm_app/app.dart';
import 'package:ytm_app/core/app_settings.dart';
import 'package:ytm_app/routing/app_router.dart';
import 'package:ytm_app/theme/app_theme.dart';
import 'package:ytm_app/theme/icons.dart';
import 'package:ytm_app/theme/tokens.dart';
import 'package:ytm_app/ui/art_tile.dart';
import 'package:ytm_app/ui/ambient/ambient_backdrop.dart';
import 'package:ytm_app/ui/glass_surface.dart';
import 'package:ytm_app/ui/pill_button.dart';
import 'package:ytm_app/ui/seek_bar.dart';
import 'package:ytm_app/ui/specimen.dart';
import 'package:ytm_app/ui/track_row.dart';

Widget _host(Widget child, {bool highContrast = false}) {
  return ProviderScope(
    child: MaterialApp(
      theme: AppTheme.dark,
      home: MediaQuery(
        data: MediaQueryData(highContrast: highContrast),
        child: Scaffold(
          backgroundColor: Tokens.bg,
          body: Center(child: SizedBox(width: 320, child: child)),
        ),
      ),
    ),
  );
}

void main() {
  group('Ambient hue synthesis', () {
    int countHueBands(List<Color> colors) {
      final List<double> bands = <double>[];
      for (final Color color in colors) {
        final double hue = HSLColor.fromColor(color).hue;
        final bool fresh = bands.every((double band) {
          final double gap = (hue - band).abs() % 360;
          return gap >= 30 && gap <= 330;
        });
        if (fresh) bands.add(hue);
      }
      return bands.length;
    }

    test('a one-hue lift gains analogous tones and keeps its own colors', () {
      // The plum variant: three lifted colors, all inside one ~30° band.
      const List<Color> mono = <Color>[
        Color(0xFF6D3AE8),
        Color(0xFFB96DFF),
        Color(0xFF2A1245),
      ];
      final List<Color> out = Tokens.diversifyAmbientHues(mono);

      expect(out.length, Tokens.ambientMaxBlobs);
      expect(out.take(mono.length), mono);
      // The ensemble now spans several hue bands: the extra blobs do not sit
      // inside the artwork's single one.
      expect(countHueBands(out), greaterThanOrEqualTo(3));
      // One synthesized tone is deliberately darker than its source.
      final double minSynthLightness = out
          .skip(mono.length)
          .fold(
            1.0,
            (double l, Color c) => l < HSLColor.fromColor(c).lightness
                ? l
                : HSLColor.fromColor(c).lightness,
          );
      expect(minSynthLightness, lessThan(0.5));
    });

    test('a genuinely multi-hue lift passes through untouched', () {
      // One color per ~30° band (purple, teal, orange).
      const List<Color> multi = <Color>[
        Color(0xFF7C6BC4),
        Color(0xFF3E8E7E),
        Color(0xFFE8935A),
      ];
      final List<Color> out = Tokens.diversifyAmbientHues(multi);
      expect(out, multi);
      expect(countHueBands(out), 3);
    });

    test('an empty palette stays empty', () {
      expect(Tokens.diversifyAmbientHues(const <Color>[]), <Color>[]);
    });
  });
  group('GlassSurface', () {
    testWidgets('blurs behind the surface by default', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _host(const GlassSurface(child: SizedBox(height: 64))),
      );
      expect(find.byType(BackdropFilter), findsOneWidget);
    });

    testWidgets('falls back to an opaque surface under high contrast', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const GlassSurface(child: SizedBox(height: 64)),
          highContrast: true,
        ),
      );
      expect(find.byType(BackdropFilter), findsNothing);
    });

    testWidgets('falls back when the setting turns transparency off', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appSettingsProvider.overrideWith(_TransparencyOff.new)],
          child: MaterialApp(
            theme: AppTheme.dark,
            home: const Scaffold(
              backgroundColor: Tokens.bg,
              body: GlassSurface(child: SizedBox(height: 64)),
            ),
          ),
        ),
      );
      expect(find.byType(BackdropFilter), findsNothing);
    });
  });

  group('PillButton', () {
    testWidgets('reports taps', (WidgetTester tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(PillButton(icon: AppIcons.play, onPressed: () => taps++)),
      );
      await tester.tap(find.byType(PillButton));
      expect(taps, 1);
    });

    testWidgets('active pill fills with the accent', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _host(
          PillButton(
            icon: AppIcons.heartFill,
            onPressed: () {},
            isActive: true,
          ),
        ),
      );
      final AnimatedContainer container = tester.widget<AnimatedContainer>(
        find.byType(AnimatedContainer),
      );
      expect(
        (container.decoration! as ShapeDecoration).color,
        Tokens.text,
        reason: 'the active pill is raised to a white fill with no accent',
      );
    });

    testWidgets('inactive pill sits on the thick glass tier with a rim', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _host(PillButton(icon: AppIcons.heart, onPressed: () {})),
      );
      final AnimatedContainer container = tester.widget<AnimatedContainer>(
        find.byType(AnimatedContainer),
      );
      final ShapeDecoration decoration =
          container.decoration! as ShapeDecoration;
      expect(
        decoration.color,
        Tokens.glassThick,
        reason: 'the inactive pill stays glass, not an opaque slab',
      );
      expect(
        decoration.shape,
        Tokens.shapePill.copyWith(
          side: BorderSide(color: Tokens.border, width: Tokens.borderWidth),
        ),
        reason: 'the hairline rim keeps the pill visible on glass panels',
      );
    });
  });

  group('ArtTile', () {
    testWidgets('renders the surface placeholder when no source is given', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_host(const ArtTile(size: Tokens.artThumbSize)));
      expect(find.byIcon(AppIcons.image), findsOneWidget);
      expect(find.byType(CachedNetworkImage), findsNothing);
    });
  });

  group('TrackRow', () {
    testWidgets('playing row uses the accent title', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const TrackRow(
            title: 'Row title',
            subtitle: 'Subtitle',
            isPlaying: true,
          ),
        ),
      );
      final TextStyle style = tester
          .widget<Text>(find.text('Row title'))
          .style!;
      expect(style.color, Tokens.text);
      expect(
        style.fontWeight,
        FontWeight.w700,
        reason: 'the playing row reads through weight and brightness, not hue',
      );
    });

    testWidgets('idle row uses primary text', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(const TrackRow(title: 'Row title', subtitle: 'Subtitle')),
      );
      expect(
        tester.widget<Text>(find.text('Row title')).style?.color,
        Tokens.text,
      );
    });

    testWidgets('reports taps', (WidgetTester tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(
          TrackRow(
            title: 'Row title',
            subtitle: 'Subtitle',
            onTap: () => taps++,
          ),
        ),
      );
      await tester.tap(find.byType(TrackRow));
      expect(taps, 1);
    });

    testWidgets('a row without a subtitle centers its title against the art', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _host(const TrackRow(title: 'Row title', subtitle: '')),
      );

      // The empty subtitle must not claim a line: with one line of text, the
      // title centers in the row exactly like the artwork does. The proof is
      // that both centers coincide.
      final double rowCenter = tester.getRect(find.byType(TrackRow)).center.dy;
      final double titleCenter = tester
          .getRect(find.text('Row title'))
          .center
          .dy;
      final double artCenter = tester
          .getRect(
            find.descendant(
              of: find.byType(TrackRow),
              matching: find.byType(ArtTile),
            ),
          )
          .center
          .dy;
      expect(titleCenter, closeTo(rowCenter, 1));
      expect(artCenter, closeTo(rowCenter, 1));
    });
  });

  group('SeekBar', () {
    testWidgets('tap seeks to the tapped fraction and commits once', (
      WidgetTester tester,
    ) async {
      final List<Duration> starts = <Duration>[];
      final List<Duration> ends = <Duration>[];
      await tester.pumpWidget(
        _host(
          SeekBar(
            position: Duration.zero,
            duration: const Duration(seconds: 100),
            onSeekStart: starts.add,
            onSeekEnd: ends.add,
          ),
        ),
      );

      final Rect rect = tester.getRect(find.byType(SeekBar));
      await tester.tapAt(Offset(rect.left + rect.width * 0.5, rect.center.dy));
      await tester.pumpAndSettle();

      expect(starts.length, 1);
      expect(ends.length, 1);
      expect(ends.single.inMilliseconds, closeTo(50000, 1200));
    });

    testWidgets('drag previews and commits a single seek', (
      WidgetTester tester,
    ) async {
      final List<Duration> ends = <Duration>[];
      var moves = 0;
      await tester.pumpWidget(
        _host(
          SeekBar(
            position: Duration.zero,
            duration: const Duration(seconds: 100),
            onSeek: (_) => moves++,
            onSeekEnd: ends.add,
          ),
        ),
      );

      final Rect rect = tester.getRect(find.byType(SeekBar));
      await tester.dragFrom(
        Offset(rect.left + rect.width * 0.1, rect.center.dy),
        Offset(rect.width * 0.4, 0),
      );
      await tester.pumpAndSettle();

      expect(moves, greaterThan(0));
      expect(ends.length, 1);
      expect(ends.single.inMilliseconds, closeTo(50000, 3000));
    });

    testWidgets('is inert when the duration is unknown', (
      WidgetTester tester,
    ) async {
      final List<Duration> ends = <Duration>[];
      var moves = 0;
      await tester.pumpWidget(
        _host(
          SeekBar(
            position: Duration.zero,
            duration: Duration.zero,
            onSeek: (_) => moves++,
            onSeekEnd: ends.add,
          ),
        ),
      );

      await tester.tapAt(tester.getRect(find.byType(SeekBar)).center);
      await tester.pumpAndSettle();

      expect(ends, isEmpty);
      expect(moves, 0);
    });

    testWidgets('is inert when disabled', (WidgetTester tester) async {
      final List<Duration> ends = <Duration>[];
      await tester.pumpWidget(
        _host(
          SeekBar(
            position: const Duration(seconds: 10),
            duration: const Duration(seconds: 100),
            enabled: false,
            onSeekEnd: ends.add,
          ),
        ),
      );

      await tester.tapAt(tester.getRect(find.byType(SeekBar)).center);
      await tester.pumpAndSettle();

      expect(ends, isEmpty);
    });
  });

  testWidgets('app clamps system text scaling to the chosen ceiling', (
    WidgetTester tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    // The specimen catalogue shows TrackRow samples, whose live badge dances
    // forever; freeze motion so pumpAndSettle can settle.
    ambientMotionEnabled = false;
    addTearDown(() => ambientMotionEnabled = true);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          initialAppSettingsProvider.overrideWithValue(
            const AppSettings(textScale: Tokens.textScaleCap),
          ),
        ],
        child: YtmApp(
          router: createAppRouter(initialLocation: devCataloguePath),
        ),
      ),
    );
    // The app waits for the music service before it builds its pages, so the
    // catalogue only exists after that step.
    await tester.pumpAndSettle();

    final BuildContext context = tester.element(find.byType(SpecimenBoard));
    expect(MediaQuery.textScalerOf(context).scale(1), Tokens.textScaleCap);
  });

  testWidgets('app boots at the standard text scale, not the ceiling', (
    WidgetTester tester,
  ) async {
    // A fresh install on a device that asks for 2x must open at the standard
    // scale: the ceiling is what the user may choose, not what they get.
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    // Freeze badge motion: the catalogue has playing TrackRow samples whose
    // tickers otherwise never let pumpAndSettle settle.
    ambientMotionEnabled = false;
    addTearDown(() => ambientMotionEnabled = true);

    await tester.pumpWidget(
      ProviderScope(
        child: YtmApp(
          router: createAppRouter(initialLocation: devCataloguePath),
        ),
      ),
    );
    // The app waits for the music service before it builds its pages, so the
    // catalogue only exists after that step.
    await tester.pumpAndSettle();

    final BuildContext context = tester.element(find.byType(SpecimenBoard));
    expect(MediaQuery.textScalerOf(context).scale(1), Tokens.textScaleDefault);
  });
}

/// A settings notifier that starts with Reduce Transparency already on.
class _TransparencyOff extends AppSettingsNotifier {
  @override
  AppSettings build() => const AppSettings(reduceTransparency: true);
}
