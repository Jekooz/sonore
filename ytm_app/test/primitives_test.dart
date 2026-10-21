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
  group('GlassSurface', () {
    testWidgets('blurs behind the surface by default', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(const GlassSurface(child: SizedBox(height: 64))),
      );
      expect(find.byType(BackdropFilter), findsOneWidget);
    });

    testWidgets('falls back to an opaque surface under high contrast',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          const GlassSurface(child: SizedBox(height: 64)),
          highContrast: true,
        ),
      );
      expect(find.byType(BackdropFilter), findsNothing);
    });

    testWidgets('falls back when the setting turns transparency off',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSettingsProvider.overrideWith(_TransparencyOff.new),
          ],
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
        _host(
          PillButton(
            icon: AppIcons.play,
            onPressed: () => taps++,
          ),
        ),
      );
      await tester.tap(find.byType(PillButton));
      expect(taps, 1);
    });

    testWidgets('active pill fills with the accent', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          PillButton(
            icon: AppIcons.heartFill,
            onPressed: () {},
            isActive: true,
          ),
        ),
      );
      final AnimatedContainer container =
          tester.widget<AnimatedContainer>(find.byType(AnimatedContainer));
      expect((container.decoration! as ShapeDecoration).color, Tokens.accent);
    });

    testWidgets('inactive pill sits on surfaceRaised', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          PillButton(icon: AppIcons.heart, onPressed: () {}),
        ),
      );
      final AnimatedContainer container =
          tester.widget<AnimatedContainer>(find.byType(AnimatedContainer));
      expect(
        (container.decoration! as ShapeDecoration).color,
        Tokens.surfaceRaised,
      );
    });
  });

  group('ArtTile', () {
    testWidgets('renders the surface placeholder when no source is given',
        (WidgetTester tester) async {
      await tester.pumpWidget(_host(const ArtTile(size: Tokens.artThumbSize)));
      expect(find.byIcon(AppIcons.image), findsOneWidget);
      expect(find.byType(CachedNetworkImage), findsNothing);
    });
  });

  group('TrackRow', () {
    testWidgets('playing row uses the accent title', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          const TrackRow(title: 'Row title', subtitle: 'Subtitle', isPlaying: true),
        ),
      );
      expect(
        tester.widget<Text>(find.text('Row title')).style?.color,
        Tokens.accent,
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
  });

  group('SeekBar', () {
    testWidgets('tap seeks to the tapped fraction and commits once',
        (WidgetTester tester) async {
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

    testWidgets('drag previews and commits a single seek',
        (WidgetTester tester) async {
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

    testWidgets('is inert when the duration is unknown',
        (WidgetTester tester) async {
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

  testWidgets('app clamps system text scaling to the chosen ceiling',
      (WidgetTester tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

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

  testWidgets('app boots at the standard text scale, not the ceiling',
      (WidgetTester tester) async {
    // A fresh install on a device that asks for 2x must open at the standard
    // scale: the ceiling is what the user may choose, not what they get.
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

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
