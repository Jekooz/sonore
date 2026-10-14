import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ytm_app/theme/app_theme.dart';
import 'package:ytm_app/theme/icons.dart';
import 'package:ytm_app/theme/tokens.dart';
import 'package:ytm_app/ui/screen_states.dart';

Widget _host(Widget child) {
  return MaterialApp(
    theme: AppTheme.dark,
    home: Scaffold(
      backgroundColor: Tokens.bg,
      body: Center(child: child),
    ),
  );
}

void main() {
  group('Skeleton', () {
    testWidgets('renders at the requested size', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          const Skeleton(width: Tokens.s48, height: Tokens.s16),
        ),
      );
      // The shimmer repeats, so settle would never finish; pump a frame.
      await tester.pump(const Duration(milliseconds: 16));

      final Size size = tester.getSize(find.byType(Skeleton));
      expect(size.width, Tokens.s48);
      expect(size.height, Tokens.s16);
    });
  });

  group('StateMessage', () {
    testWidgets('shows one sentence and one action', (WidgetTester tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(
          StateMessage(
            message: 'Nothing is playing yet.',
            actionLabel: 'Browse library',
            onAction: () => taps++,
          ),
        ),
      );

      expect(find.text('Nothing is playing yet.'), findsOneWidget);
      await tester.tap(find.text('Browse library'));
      expect(taps, 1);
    });

    testWidgets('omits the action when there is nothing to do',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(const StateMessage(message: 'Nothing is up next.')),
      );

      expect(find.text('Nothing is up next.'), findsOneWidget);
      expect(find.byType(ElevatedButton), findsNothing);
    });

    testWidgets('error and offline variants use neutral text, not red',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          const StateMessage(
            message: "You're offline.",
            footnote: 'Only cached music is available.',
            actionLabel: 'Retry',
          ),
        ),
      );

      expect(find.text("You're offline."), findsOneWidget);
      expect(find.text('Only cached music is available.'), findsOneWidget);

      final Text message = tester.widget<Text>(find.text("You're offline."));
      expect(message.style?.color, Tokens.text);
      expect(message.style?.color, isNot(Tokens.accent));
    });
  });

  testWidgets('the app icon set stays at 24px', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(const Icon(AppIcons.heart, size: Tokens.iconSize)),
    );
    expect(tester.getSize(find.byIcon(AppIcons.heart)).width, Tokens.iconSize);
  });
}
