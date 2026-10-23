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
      iconTheme: const IconThemeData(color: Tokens.text, size: Tokens.iconSize),
      pageTransitionsTheme: const PageTransitionsTheme(
        // The same fade-and-rise on every platform the app ships on — there is
        // no docker, cupertino or zoom zooming here: one motion language.
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.windows: AppPageTransitions(),
          TargetPlatform.android: AppPageTransitions(),
          TargetPlatform.macOS: AppPageTransitions(),
          TargetPlatform.linux: AppPageTransitions(),
          TargetPlatform.iOS: AppPageTransitions(),
          TargetPlatform.fuchsia: AppPageTransitions(),
        },
      ),
      // Tooltips are solid surfaces in token colors, never Material's
      // default gray: they satisfy the reduce-transparency rule (everything
      // floating is opaque and concentric) even before any tier change.
      tooltipTheme: TooltipThemeData(
        decoration: ShapeDecoration(
          color: Tokens.glassFallback,
          shape: Tokens.shapeFor(Tokens.rSmall).copyWith(
            side: BorderSide(color: Tokens.border, width: Tokens.borderWidth),
          ),
        ),
        textStyle: Tokens.caption.copyWith(color: Tokens.text),
        waitDuration: const Duration(milliseconds: 500),
      ),
    );
  }
}

/// The app's route transition: a fade in [Tokens.curvePageChange] over
/// [Tokens.dPageChange], with a low rise so a page settles rather than
/// slides across the window.
///
/// Reduce Motion folds it into a plain cross-fade that completes within
/// [Tokens.dReduceMotionFade] of the route's own duration window, so no
/// animation carries a page above the user's preference (spec: "all gated by
/// Reduce motion").
class AppPageTransitions extends PageTransitionsBuilder {
  const AppPageTransitions();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final bool reduced = MediaQuery.disableAnimationsOf(context);
    final Curve fadeCurve = reduced
        ? Interval(
            0,
            Tokens.dReduceMotionFade.inMilliseconds /
                route.transitionDuration.inMilliseconds,
            curve: Curves.linear,
          )
        : Tokens.curvePageChange;
    final Animation<double> fade = animation.drive(
      CurveTween(curve: fadeCurve),
    );
    if (reduced) {
      return FadeTransition(opacity: fade, child: child);
    }
    // The rise is expressed as a fraction of the page height, so the motion
    // reads identically at every window size.
    return FadeTransition(
      opacity: fade,
      child: SlideTransition(
        position: animation.drive(
          Tween<Offset>(
            begin: const Offset(0, 0.02),
            end: Offset.zero,
          ).chain(CurveTween(curve: Tokens.curvePageChange)),
        ),
        child: child,
      ),
    );
  }
}
