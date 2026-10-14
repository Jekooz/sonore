import 'package:flutter/material.dart';

/// design.md section 2 — the POC's single source of truth for colour.
///
/// Values are the ones the document specifies and the ones the shipped WinUI
/// app already uses (`frontend/Themes/DesignTokens.xaml`), so the two frontends
/// agree while the migration is in flight.
abstract final class Tokens {
  static const Color bg = Color(0xFF000000); // #000000
  static const Color surface = Color(0xFF141417); // #141417
  static const Color raised = Color(0xFF1C1C21); // #1C1C21
  static const Color accent = Color(0xFFFA2D48); // #FA2D48
  static const Color textPrimary = Color(0xFFFFFFFF); // #FFFFFF
  static const Color textSecondary = Color(0xFFA6A6A6); // #A6A6A6
  static const Color textTertiary = Color(0xFF7A7A7A); // #7A7A7A

  // Spacing scale: only 4, 8, 12, 16, 24, 32 (design.md section 2).
  static const double s4 = 4;
  static const double s8 = 8;
  static const double s12 = 12;
  static const double s16 = 16;
  static const double s24 = 24;
  static const double s32 = 32;

  static ThemeData theme() => ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: bg,
        colorScheme: const ColorScheme.dark(
          surface: surface,
          primary: accent,
          onPrimary: textPrimary,
          secondary: accent,
          onSurface: textPrimary,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: bg,
          foregroundColor: textPrimary,
          elevation: 0,
        ),
        sliderTheme: const SliderThemeData(
          activeTrackColor: accent,
          thumbColor: textPrimary,
          inactiveTrackColor: raised,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: raised,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none,
          ),
          hintStyle: const TextStyle(color: textTertiary),
        ),
        textTheme: const TextTheme(
          titleLarge: TextStyle(color: textPrimary, fontSize: 28, fontWeight: FontWeight.w700),
          titleMedium: TextStyle(color: textPrimary, fontSize: 18, fontWeight: FontWeight.w600),
          bodyMedium: TextStyle(color: textPrimary, fontSize: 14),
          bodySmall: TextStyle(color: textSecondary, fontSize: 13),
          labelSmall: TextStyle(color: textTertiary, fontSize: 12),
        ),
      );
}

/// mm:ss for the seek bar ends (design.md section 3.E).
String formatDuration(Duration d) {
  if (d < Duration.zero) d = Duration.zero;
  final m = d.inMinutes.remainder(60).toString();
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return d.inHours > 0 ? '${d.inHours}:${m.padLeft(2, '0')}:$s' : '$m:$s';
}
