import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_settings.dart';
import '../theme/tokens.dart';

/// The one and only place the app may call [BackdropFilter].
///
/// The spec bans `BackdropFilter` outside `GlassSurface`, so every floating
/// chrome surface (top bar, bottom nav, mini player, transport pill, sheets)
/// is built from this widget.
///
/// Recipe: clip to the shape, then compose a 30-sigma blur with 1.8x
/// saturation, then paint the glass/glassStrong fill and a 1px border.
/// Floating pills add a specular streak; the surface casts a soft shadow.
/// Reduce Transparency (or a device that drops frames) switches to
/// surfaceRaised at 92% opacity.
class GlassSurface extends ConsumerWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.radius = Tokens.rCard,
    this.shape,
    this.isStrong = false,
    this.showSpecular = true,
  });

  final Widget child;

  /// Corner radius token. Ignored when [shape] is given.
  final double radius;

  /// Overrides the shape entirely, e.g. [Tokens.shapePill] for the mini player.
  final OutlinedBorder? shape;

  /// Use the stronger 10% fill (mini player, transport pill, sheets).
  final bool isStrong;

  /// Whether to paint the specular streak (floating pills only).
  final bool showSpecular;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings = ref.watch(appSettingsProvider);
    final MediaQueryData media = MediaQuery.of(context);

    final bool reduceTransparency =
        settings.reduceTransparency || media.highContrast;

    final OutlinedBorder resolved = shape ?? Tokens.shapeFor(radius);

    if (reduceTransparency) {
      return DecoratedBox(
        decoration: ShapeDecoration(color: Tokens.glassFallback, shape: resolved),
        child: child,
      );
    }

    final ShapeBorder bordered = resolved.copyWith(
      side: const BorderSide(color: Tokens.border, width: Tokens.borderWidth),
    );

    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        // Soft shadow under the floating chrome, cast from the shape itself.
        Positioned.fill(
          child: DecoratedBox(
            decoration: ShapeDecoration(
              color: Tokens.transparent,
              shape: resolved,
              shadows: const <BoxShadow>[
                BoxShadow(
                  offset: Offset(0, Tokens.glassShadowOffset),
                  blurRadius: Tokens.glassShadowBlur,
                  color: Tokens.shadow,
                ),
              ],
            ),
          ),
        ),
        ClipPath(
          clipper: ShapeBorderClipper(
            shape: resolved,
            textDirection: Directionality.maybeOf(context),
          ),
          child: BackdropFilter(
            filter: ImageFilter.compose(
              outer: ColorFilter.matrix(
                Tokens.saturationMatrix(Tokens.glassSaturation),
              ),
              inner: ImageFilter.blur(
                sigmaX: Tokens.glassBlur,
                sigmaY: Tokens.glassBlur,
              ),
            ),
            child: DecoratedBox(
              decoration: ShapeDecoration(
                color: isStrong ? Tokens.glassStrong : Tokens.glass,
                shape: bordered,
              ),
              child: Stack(
                children: <Widget>[
                  if (showSpecular)
                    const Positioned.fill(
                      child: IgnorePointer(child: _SpecularStreak()),
                    ),
                  child,
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A 120-degree linear gradient from white 16% to transparent at 60%.
///
/// It is a highlight, never a colored glow. Clipped to the surface shape by the
/// enclosing [ClipPath].
class _SpecularStreak extends StatelessWidget {
  const _SpecularStreak();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Tokens.specularBegin,
          end: Tokens.specularEnd,
          stops: <double>[0, Tokens.glassSpecularStop],
          colors: <Color>[Tokens.specular, Tokens.transparent],
        ),
      ),
    );
  }
}
