import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_settings.dart';
import '../core/visual_quality.dart';
import '../theme/tokens.dart';
import 'ambient/ambient_palette.dart';

/// The strength of a [GlassSurface].
///
/// One widget owns the glass recipe and everything routes through it — the
/// app-wide rule is that `BackdropFilter` exists only here. The tiers differ
/// only in the numbers spoken by [Tokens]: blur sigma and fill opacity.
enum GlassTier {
  /// Rows, quiet cards, inputs: blur [Tokens.glassBlurThin], white 6%.
  thin,

  /// Navigation pill, tab bar, hero, standard cards: blur
  /// [Tokens.glassBlurRegular], white 9%.
  regular,

  /// Transport pill, Now Playing bar, sheets, dialogs, menus: blur
  /// [Tokens.glassBlurThick], white 14%.
  thick,
}

/// The decoration for a selected navigation item: a raised pane of lighter
/// glass — a lit white ramp with a hairline specular rim — rather than a dark
/// fill that reads as a hole punched in the bar.
ShapeDecoration navSelectionDecoration(OutlinedBorder shape) => ShapeDecoration(
  gradient: const LinearGradient(
    begin: Tokens.edgeBegin,
    end: Tokens.edgeEnd,
    colors: <Color>[Tokens.navSelectionTop, Tokens.navSelectionBottom],
  ),
  shape: shape.copyWith(
    side: BorderSide(color: Tokens.border, width: Tokens.borderWidth),
  ),
);

/// The blur and fill each tier speaks, from [Tokens]. Kept here rather than
/// on the enum so the enum stays a pure choice and the numbers stay in one
/// [Tokens] module.
extension GlassTierRecipe on GlassTier {
  /// Backdrop blur sigma for this tier.
  double get blur => switch (this) {
    GlassTier.thin => Tokens.glassBlurThin,
    GlassTier.regular => Tokens.glassBlurRegular,
    GlassTier.thick => Tokens.glassBlurThick,
  };

  /// White fill over the blurred backdrop for this tier.
  Color get fill => switch (this) {
    GlassTier.thin => Tokens.glassThin,
    GlassTier.regular => Tokens.glassRegular,
    GlassTier.thick => Tokens.glassThick,
  };
}

/// The one and only place the app may call [BackdropFilter].
///
/// Every glass surface (top bar, bottom nav, Now Playing bar, transport pill,
/// cards, sheets, dialogs, menus, inputs) is built from this widget.
///
/// Recipe, painted bottom-up in the same order:
///  1. clip to the shape;
///  2. a backdrop blur composed with a ~1.6x saturation boost;
///  3. the tier's white fill;
///  4. a 1px *gradient* border — white 30% at the top-left corner falling to
///     white 5% at the bottom-right — plus a soft top inner highlight;
///  5. floating surfaces only: the 120° specular streak and a soft drop
///     shadow. Docked surfaces (the anchored Now Playing bar) paint neither,
///     so they read as part of the layout rather than as a hovering card.
///
/// Reduce Transparency (the OS high-contrast setting included) swaps the whole
/// recipe for a *solid, tinted* surface: an opaque gradient derived from the
/// current ambient palette, pulled far toward the dark base so it never
/// competes with content. Layout, radii and contrast are identical in either
/// state — only the fill solidifies.
class GlassSurface extends ConsumerWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.tier = GlassTier.regular,
    this.radius = Tokens.rCard,
    this.shape,
    this.showSpecular = true,
    this.isFloating = true,
  });

  final Widget child;

  /// How much blur and fill this surface gets.
  final GlassTier tier;

  /// Corner radius token. Ignored when [shape] is given.
  final double radius;

  /// Overrides the shape entirely, e.g. [Tokens.shapePill] for the navigation
  /// pill or [Tokens.shapeAnchoredBar] for the docked Now Playing bar.
  final OutlinedBorder? shape;

  /// Whether to paint the specular streak (floating surfaces only).
  final bool showSpecular;

  /// Whether this surface floats above the page. Docked surfaces are flush
  /// with the layout edge, so they skip both the drop shadow and the specular
  /// streak. Their blur and translucency are kept, because the anchored Now
  /// Playing bar may still use the glass treatment.
  final bool isFloating;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings = ref.watch(appSettingsProvider);
    final MediaQueryData media = MediaQuery.of(context);
    final VisualQualityTier quality = ref.watch(visualQualityProvider);

    final bool reduceTransparency =
        settings.reduceTransparency ||
        media.highContrast ||
        // Visual quality Low is the full fallback: solid surfaces rather
        // than blur on a device that said no.
        quality == VisualQualityTier.low;
    final double blurFactor = quality == VisualQualityTier.low
        ? Tokens.reducedBlurFactor
        : 1;

    final OutlinedBorder resolved = shape ?? Tokens.shapeFor(radius);
    final TextDirection? textDirection = Directionality.maybeOf(context);

    if (reduceTransparency) {
      return _GlassShell(
        shape: resolved,
        textDirection: textDirection,
        isFloating: isFloating,
        // Solid, palette-tinted ramp instead of a blur. One hue, barely there,
        // running top-left to bottom-right like the glass edge would — so the
        // fallback is a designed surface, not an afterthought.
        child: ClipPath(
          clipper: ShapeBorderClipper(
            shape: resolved,
            textDirection: textDirection,
          ),
          child: DecoratedBox(
            decoration: ShapeDecoration(
              gradient: LinearGradient(
                begin: Tokens.edgeBegin,
                end: Tokens.edgeEnd,
                colors: _fallbackTints(ref, tier),
              ),
              shape: resolved.copyWith(
                side: BorderSide(
                  color: Tokens.edgeStrong,
                  width: Tokens.borderWidth,
                ),
              ),
            ),
            child: child,
          ),
        ),
      );
    }

    final Widget surface = ClipPath(
      clipper: ShapeBorderClipper(
        shape: resolved,
        textDirection: textDirection,
      ),
      child: BackdropFilter(
        filter: ImageFilter.compose(
          outer: ColorFilter.matrix(
            Tokens.saturationMatrix(Tokens.glassSaturation),
          ),
          inner: ImageFilter.blur(
            sigmaX: tier.blur * blurFactor,
            sigmaY: tier.blur * blurFactor,
          ),
        ),
        child: DecoratedBox(
          decoration: ShapeDecoration(color: tier.fill, shape: resolved),
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _GlassEdgePainter(
                      shape: resolved,
                      textDirection: textDirection,
                    ),
                  ),
                ),
              ),
              if (showSpecular && isFloating)
                const Positioned.fill(
                  child: IgnorePointer(child: _SpecularStreak()),
                ),
              child,
            ],
          ),
        ),
      ),
    );

    if (!isFloating) return surface;

    return _GlassShell(
      shape: resolved,
      textDirection: textDirection,
      isFloating: isFloating,
      child: surface,
    );
  }

  /// The solid fallback ramp for one tier, tinted from the current ambient
  /// palette: each palette color is pulled ~82% of the way toward the dark
  /// base, so the fallback *whispers* the artwork instead of announcing it.
  /// With no palette yet (idle, or reduce-transparency before the first track)
  /// it falls back to the neutral [Tokens.glassFallback] tints — which is also
  /// what keeps the fallback stable for tests that pin no palette.
  static List<Color> _fallbackTints(WidgetRef ref, GlassTier tier) {
    final List<Color> palette = ref.watch(
      ambientPaletteProvider.select(
        (AmbientPaletteState state) => state.colors,
      ),
    );

    if (palette.isEmpty) {
      return switch (tier) {
        GlassTier.thin => <Color>[
          Tokens.glassFallbackThin,
          Tokens.glassFallbackThin,
        ],
        GlassTier.regular ||
        GlassTier.thick => <Color>[Tokens.glassFallback, Tokens.glassFallback],
      };
    }

    final Color top = Color.lerp(palette[0], Tokens.bg, 0.82)!;
    final Color bottom = palette.length > 1
        ? Color.lerp(palette[1], Tokens.bg, 0.82)!
        : top;
    return <Color>[top, bottom];
  }
}

/// Shared shell for a glass pane: the shadow a floating surface casts around
/// the pane. The pane is passed as [child]; the fallback path uses the same
/// shell so geometry and shadow match the glass path exactly.
class _GlassShell extends StatelessWidget {
  const _GlassShell({
    required this.child,
    required this.shape,
    required this.isFloating,
    required this.textDirection,
  });

  final Widget child;
  final OutlinedBorder shape;
  final bool isFloating;
  final TextDirection? textDirection;

  @override
  Widget build(BuildContext context) {
    if (!isFloating) return child;

    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        // Soft shadow under the floating chrome, cast from the shape itself.
        // A docked surface is part of the layout, so it never casts one.
        Positioned.fill(
          child: DecoratedBox(
            decoration: ShapeDecoration(
              color: Tokens.transparent,
              shape: shape,
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
        child,
      ],
    );
  }
}

/// The glass edge drawing: one painter, two shaders.
///
///  * the 1px gradient border, white ~30% top-left → white ~5% bottom-right;
///  * the top inner highlight, a vertical band from white ~12% that dies by
///    [Tokens.glassHighlightStop] of the surface height — the light falls on
///    the top edge of the pane and nothing else.
///
/// A pane never draws a colored glow: every value here is white.
class _GlassEdgePainter extends CustomPainter {
  const _GlassEdgePainter({required this.shape, required this.textDirection});

  final ShapeBorder shape;
  final TextDirection? textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    final Path path = shape.getOuterPath(rect, textDirection: textDirection);

    // The gradient border follows the pane edge and reads as a specular line.
    // The stroke straddles the outline; the outer half is shaved off by the
    // enclosing clip, leaving exactly one px inside.
    final Paint border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = Tokens.borderWidth * 2
      ..shader = LinearGradient(
        begin: Tokens.edgeBegin,
        end: Tokens.edgeEnd,
        colors: const <Color>[Tokens.edgeStrong, Tokens.edgeFaint],
      ).createShader(rect, textDirection: textDirection);
    canvas.drawPath(path, border);

    // Top inner highlight: a soft band across the top of the pane.
    final Paint highlight = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        stops: const <double>[0, Tokens.glassHighlightStop],
        colors: const <Color>[Tokens.highlightTop, Tokens.transparent],
      ).createShader(rect, textDirection: textDirection);
    canvas.drawPath(path, highlight);
  }

  @override
  bool shouldRepaint(_GlassEdgePainter oldDelegate) =>
      oldDelegate.shape != shape || oldDelegate.textDirection != textDirection;
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
