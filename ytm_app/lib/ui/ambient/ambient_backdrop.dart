import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/visual_quality.dart';
import '../../theme/tokens.dart';
import 'ambient_palette.dart';

/// Set to false wherever a fully deterministic frame is required (tests and
/// goldens via `pumpAtSize`). Only the *drift* reads it — palette lifting,
/// cross-fade keys and grain are all deterministic regardless.
bool ambientMotionEnabled = true;

/// The seeded grain texture, generated once per session.
///
/// Pure white pixels with a narrow random alpha band, painted tiled at
/// [Tokens.grainOpacity] over the whole backdrop: a film of noise that hides
/// the banded gradients the blobs otherwise show on wide low-color displays.
/// The seed is fixed, so the texture — and every golden — is reproducible.
final FutureProvider<ui.Image?> grainTextureProvider =
    FutureProvider<ui.Image?>((ref) async {
      final int size = Tokens.grainSize;
      final math.Random random = math.Random(7);
      final Uint8List raw = Uint8List(size * size * 4);
      for (int i = 0; i < size * size; i++) {
        raw[i * 4] = 255;
        raw[i * 4 + 1] = 255;
        raw[i * 4 + 2] = 255;
        raw[i * 4 + 3] = random.nextInt(Tokens.grainMaxAlpha);
      }

      final Completer<ui.Image> done = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        raw,
        size,
        size,
        ui.PixelFormat.rgba8888,
        done.complete,
      );
      return done.future;
    });

/// The one ambient layer behind the whole app.
///
/// Composition, back to front:
///  1. the dark base ([Tokens.bg]);
///  2. the artwork layer — the current track's palette painted as large soft
///     radial blobs, drifting slowly, cross-fading on track change — or, when
///     nothing plays, the neutral monochrome ramp;
///  3. the legibility veil, a dark wash whose strength adapts to the palette
///     brightness so chrome text holds 4.5:1 over the surface below;
///  4. the grain.
///
/// The whole layer sits inside one RepaintBoundary and schedules no frames of
/// its own except during a drift move and a palette cross-fade, so the idle
/// scroll cost of glass screens is their own blur, never the backdrop.
class AmbientBackdrop extends ConsumerStatefulWidget {
  const AmbientBackdrop({super.key});

  @override
  ConsumerState<AmbientBackdrop> createState() => _AmbientBackdropState();
}

class _AmbientBackdropState extends ConsumerState<AmbientBackdrop> {
  final List<Offset> _drift = <Offset>[Offset.zero, Offset.zero, Offset.zero];
  Timer? _timer;
  final math.Random _random = math.Random(11);

  @override
  void initState() {
    super.initState();
  }

  /// One nudge per period; each blob then eases to its new offset over the
  /// move window. An implicit animation rather than a running ticker: between
  /// nudges no frame is scheduled at all, so the idle cost of the backdrop is
  /// literally zero. Scheduled from [didChangeDependencies] because the gate
  /// reads the system's Reduce Motion setting through [MediaQuery], which is
  /// not an ancestor yet during [initState].
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleDrift();
  }

  void _scheduleDrift() {
    _timer?.cancel();
    // Visual quality Low freezes the drift along with thinning the blur: the
    // blob layer then repaints only on a track change, never per interval.
    final VisualQualityTier quality = ref.read(visualQualityProvider);
    if (ambientMotionEnabled &&
        quality != VisualQualityTier.low &&
        !MediaQuery.of(context).disableAnimations) {
      _timer = Timer.periodic(Tokens.ambientDriftPeriod, (_) => _nudge());
    }
  }

  void _nudge() {
    if (!mounted) return;
    setState(() {
      for (int i = 0; i < _drift.length; i++) {
        _drift[i] = Offset(
          _random.nextDouble() * Tokens.ambientDriftSpan -
              Tokens.ambientDriftSpan / 2,
          _random.nextDouble() * Tokens.ambientDriftSpan -
              Tokens.ambientDriftSpan / 2,
        );
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AmbientPaletteState palette = ref.watch(ambientPaletteProvider);
    final ui.Image? grain = ref.watch(grainTextureProvider).value;
    // Reaction to a tier change: Low freezes, any other tier restarts the
    // drift with the current timer schedule.
    ref.listen<VisualQualityTier>(visualQualityProvider, (
      VisualQualityTier? previous,
      VisualQualityTier next,
    ) {
      _scheduleDrift();
    });

    final String layerKey = palette.key.isEmpty ? 'idle' : palette.key;
    // With nothing playing the blob layer keeps running on a neutral mono-
    // chrome palette, so the resting app is still atmosphere — the same drift,
    // the same three anchors — and glass never blurs a dead-black field.
    final List<Color> blobColors = palette.colors.isEmpty
        ? Tokens.backdropNeutralBlobs
        : palette.colors;

    return IgnorePointer(
      child: RepaintBoundary(
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            const ColoredBox(color: Tokens.bg),
            AnimatedSwitcher(
              duration: MediaQuery.of(context).disableAnimations
                  ? Duration.zero
                  : Tokens.dAmbientCrossfade,
              child: KeyedSubtree(
                key: ValueKey<String>(layerKey),
                child: _BackdropBlobs(colors: blobColors, drift: _drift),
              ),
            ),
            _LegibilityVeil(colors: palette.colors),
            // The calm zone: blobs die into the base behind the bottom
            // chrome, so its glass reads as a lit pane over dark rather than
            // cut from a bright halo.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: Tokens.ambientBottomCalm,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: const <Color>[Tokens.bg, Tokens.transparent],
                  ),
                ),
              ),
            ),
            if (grain != null) _Grain(texture: grain),
          ],
        ),
      ),
    );
  }
}

/// The blob layer: each color is one large soft radial blob anchored on
/// [Tokens.ambientPlacements], plus a drift offset. Radial gradients only —
/// a blur filter over the full screen would be exactly the cost the
/// performance budget forbids.
class _BackdropBlobs extends StatelessWidget {
  const _BackdropBlobs({required this.colors, required this.drift});

  final List<Color> colors;
  final List<Offset> drift;

  @override
  Widget build(BuildContext context) {
    final bool motionOn =
        ambientMotionEnabled && !MediaQuery.of(context).disableAnimations;

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        for (
          int i = 0;
          i < colors.length && i < Tokens.ambientPlacements.length;
          i++
        )
          AnimatedAlign(
            duration: motionOn ? Tokens.ambientDriftMove : Duration.zero,
            curve: Tokens.curvePress,
            alignment: _shifted(i),
            child: FractionallySizedBox(
              widthFactor: Tokens.ambientBlobExtent,
              heightFactor: Tokens.ambientBlobExtent,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: <Color>[
                      colors[i].withValues(alpha: Tokens.ambientBlobOpacity),
                      colors[i].withValues(alpha: 0),
                    ],
                  ),
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
      ],
    );
  }

  Alignment _shifted(int index) {
    final Alignment base =
        Tokens.ambientPlacements[index % Tokens.ambientPlacements.length];
    final Offset offset = drift[index % drift.length];
    return Alignment(base.x + offset.dx, base.y + offset.dy);
  }
}

/// The legibility veil: a black wash over the art layer whose strength is the
/// adaptive part of the contrast guarantee. The mean brightness of the palette
/// decides how heavy it is — never below [Tokens.ambientVeilMinAlpha], never
/// above [Tokens.ambientVeilMaxAlpha] — so white chrome text holds 4.5:1
/// against the plainest possible surface below it. Small text still never
/// sits directly on the layer itself: the screens own the guarantee for
/// metadata and captions over panels.
class _LegibilityVeil extends StatelessWidget {
  const _LegibilityVeil({required this.colors});

  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    if (colors.isEmpty) {
      // No palette: the neutral ramp is already dim, keep only its floor.
      return ColoredBox(
        color: Tokens.transparent.withValues(alpha: Tokens.ambientVeilMinAlpha),
      );
    }

    double total = 0;
    for (final Color color in colors.take(Tokens.ambientColorCount)) {
      total += Tokens.lumaOf(color);
    }
    final double mean =
        total / math.min(Tokens.ambientColorCount, colors.length);
    final double alpha =
        Tokens.ambientVeilMinAlpha +
        (Tokens.ambientVeilMaxAlpha - Tokens.ambientVeilMinAlpha) * mean;

    return ColoredBox(
      color: Tokens.transparent.withValues(alpha: alpha.clamp(0.0, 1.0)),
    );
  }
}

/// Tiles the seeded grain across the backdrop. The RepaintBoundary is already
/// around the whole layer; the painter is trivial and static.
class _Grain extends StatelessWidget {
  const _Grain({required this.texture});

  final ui.Image texture;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _GrainPainter(texture: texture));
  }
}

class _GrainPainter extends CustomPainter {
  const _GrainPainter({required this.texture});

  final ui.Image texture;

  @override
  void paint(Canvas canvas, Size size) {
    paintImage(
      canvas: canvas,
      rect: Offset.zero & size,
      image: texture,
      repeat: ImageRepeat.repeat,
      opacity: Tokens.grainOpacity,
      filterQuality: FilterQuality.none,
      isAntiAlias: false,
    );
  }

  @override
  bool shouldRepaint(_GrainPainter oldDelegate) =>
      oldDelegate.texture != texture;
}
