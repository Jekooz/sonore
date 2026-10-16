import 'package:flutter/material.dart';

import 'tokens.dart';

/// A resolved set of color roles for one brightness. The dark instance wraps
/// [Tokens] verbatim; the light instance is an implementation decision — the
/// Figma spec only defines the dark palette ("Resonance for Windows"), so the
/// light values below mirror its structure with inversed neutrals and are
/// documented here rather than claimed as design data.
class Palette {
  const Palette._(
    // Field order matches the Tokens section it mirrors.
    this.bg,
    this.surface,
    this.surfaceRaised,
    this.glass,
    this.glassStrong,
    this.glassFallback,
    this.border,
    this.borderStrong,
    this.accent,
    this.text,
    this.textSecondary,
    this.textMuted,
    this.scrim,
    this.specular,
    this.shadow,
  );

  /// Page background.
  final Color bg;

  /// Opaque panels: sidebar, sheets.
  final Color surface;

  /// Cards and raised controls.
  final Color surfaceRaised;

  /// Floating chrome tint (8% white in dark, 8% black in light).
  final Color glass;

  /// Prominent floating chrome tint (10% white in dark, 12% black in light).
  final Color glassStrong;

  /// Solid fallback when backdrop blur is unavailable. Layout and contrast
  /// must not change when the fallback engages.
  final Color glassFallback;

  /// Hairlines on glass (10%).
  final Color border;

  /// Focused / prominent outline (16%).
  final Color borderStrong;

  /// Accent — the same brand red in both themes.
  final Color accent;

  /// Titles, active labels.
  final Color text;

  /// Subtitles, metadata.
  final Color textSecondary;

  /// Durations, hints, large text only.
  final Color textMuted;

  /// Modal backdrop.
  final Color scrim;

  /// Specular streak start.
  final Color specular;

  /// Shadow under floating chrome.
  final Color shadow;

  static const Palette dark = Palette._(
    /*
     * Every field reads [Tokens]; the dark palette IS the token set.
     */
    Tokens.bg,
    Tokens.surface,
    Tokens.surfaceRaised,
    Tokens.glass,
    Tokens.glassStrong,
    Tokens.glassFallback,
    Tokens.border,
    Tokens.borderStrong,
    Tokens.accent,
    Tokens.text,
    Tokens.textSecondary,
    Tokens.textMuted,
    Tokens.scrim,
    Tokens.specular,
    Tokens.shadow,
  );

  /*
   * Light palette — implementation decisions (no Figma basis). Neutrals are
   * inversed into a cool quiet gray family that keeps the same structural
   * relationships as dark: background differs from surface, cards raise above
   * both, glass tints darken slightly, the accent red is unchanged. Contrast
   * checked against the same rules the dark palette follows: secondary 4.5:1,
   * muted reserved for large text.
   */
  static const Palette light = Palette._(
    Color(0xFFFFFFFF), /* bg */
    Color(0xFFF2F2F5), /* surface */
    Color(0xFFFFFFFF), /* surfaceRaised */
    Color(0x14000000), /* glass — black 8% (mirrors dark's white 8%) */
    Color(0x1F000000), /* glassStrong — black 12% */
    Color(0xFFF0F0F4), /* glassFallback */
    Color(0x1A000000), /* border — black 10% */
    Color(0x29000000), /* borderStrong — black 16% */
    Tokens.accent,
    Color(0xFF16161A), /* text */
    Color(0xFF5C5C64), /* textSecondary — 6.2:1 on white */
    Color(0xFF787880), /* textMuted — large text only */
    Color(0x73000000), /* scrim — black 45% */
    Tokens.specular,
    Color(0x1F000000), /* shadow — black 12% */
  );
}

/// ThemeData built only from token palettes. The spec bans default Material
/// colors, elevation tints and ripples, so the scheme is token-built and every
/// splash and hover tint is disabled.
class AppTheme {
  AppTheme._();

  static ThemeData get dark => build(Palette.dark);

  static ThemeData get light => build(Palette.light);

  static ThemeData build(Palette p) {
    final bool darkMode = p.bg.computeLuminance() < 0.5;
    final ColorScheme scheme = darkMode
        ? ColorScheme.dark(
            primary: p.accent,
            onPrimary: p.text,
            surface: p.surface,
            onSurface: p.text,
            outline: p.border,
            outlineVariant: p.borderStrong,
            // The spec asks for error states with no red, so the error role is
            // neutral text rather than a second accent.
            error: p.text,
            onError: p.bg,
          )
        : ColorScheme.light(
            primary: p.accent,
            // Identity color literal, not a Material default: the accent
            // CTA always wears white text in both themes.
            onPrimary: Color(0xFFFFFFFF),
            surface: p.surface,
            onSurface: p.text,
            outline: p.border,
            outlineVariant: p.borderStrong,
            error: p.text,
            onError: p.bg,
          );

    return ThemeData(
      useMaterial3: true,
      brightness: darkMode ? Brightness.dark : Brightness.light,
      fontFamily: Tokens.fontFamily,
      colorScheme: scheme,
      scaffoldBackgroundColor: p.bg,
      canvasColor: p.bg,
      splashFactory: NoSplash.splashFactory,
      splashColor: Tokens.transparent,
      highlightColor: Tokens.transparent,
      hoverColor: Tokens.transparent,
      focusColor: Tokens.transparent,
      dividerColor: p.border,
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
