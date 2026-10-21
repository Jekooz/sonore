import 'package:flutter/material.dart';

import 'tokens.dart';

/// ThemeData built only from [Tokens]. The spec bans default Material colors,
/// elevation tints and ripples, so the scheme is token-built and every splash
/// and hover tint is disabled.
///
/// The chrome is monochrome: primary is white. Every chroma on screen comes
/// from the artwork-derived ambient backdrop, so the scheme adds no hue of its
/// own — Material controls (switches, sliders, progress) render in white.
///
/// Scaffold backgrounds are transparent by default: the app's ambient backdrop
/// lives behind the shell and pages sit directly on it, so any hard `bg` fill
/// on a screen would paint the ambience out.
class AppTheme {
  AppTheme._();

  static ThemeData get dark {
    const ColorScheme scheme = ColorScheme.dark(
      primary: Tokens.text,
      onPrimary: Tokens.bg,
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
      // Pages are drawn on the ambient backdrop; nothing paints solid behind
      // them. (Screens that need an opaque fill for a dialog or gate use the
      // Tokens.bg directly.)
      scaffoldBackgroundColor: Tokens.transparent,
      canvasColor: Tokens.transparent,
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
