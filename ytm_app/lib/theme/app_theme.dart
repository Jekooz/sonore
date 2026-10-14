import 'package:flutter/material.dart';

import 'tokens.dart';

/// ThemeData built only from [Tokens]. The spec bans default Material colors,
/// elevation tints and ripples, so the scheme is token-built and every splash
/// and hover tint is disabled.
class AppTheme {
  AppTheme._();

  static ThemeData get dark {
    const ColorScheme scheme = ColorScheme.dark(
      primary: Tokens.accent,
      onPrimary: Tokens.text,
      surface: Tokens.surface,
      onSurface: Tokens.text,
      outline: Tokens.border,
      outlineVariant: Tokens.borderStrong,
      // The spec asks for error states with no red, so the error role is
      // neutral text rather than a second accent.
      error: Tokens.text,
      onError: Tokens.bg,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: Tokens.fontFamily,
      colorScheme: scheme,
      scaffoldBackgroundColor: Tokens.bg,
      canvasColor: Tokens.bg,
      splashFactory: NoSplash.splashFactory,
      splashColor: Tokens.transparent,
      highlightColor: Tokens.transparent,
      hoverColor: Tokens.transparent,
      focusColor: Tokens.transparent,
      dividerColor: Tokens.border,
      textTheme: const TextTheme(
        displayLarge: Tokens.pageTitle,
        titleLarge: Tokens.sectionHeader,
        titleMedium: Tokens.rowTitle,
        bodyMedium: Tokens.subtitle,
        bodySmall: Tokens.caption,
      ),
      iconTheme: const IconThemeData(
        color: Tokens.text,
        size: Tokens.iconSize,
      ),
    );
  }
}
