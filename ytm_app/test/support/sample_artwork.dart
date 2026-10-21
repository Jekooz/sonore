/// Deterministic, vivid fixture artwork for tests and goldens.
///
/// Every fixture URL maps to one of six hand-tuned gradient variants,
/// rendered per-pixel into a cached [ui.Image]. Real gradients give the
/// glass something to refract and the ambient backdrop colors to lift;
/// hashing keeps the whole set reproducible so goldens never change between
/// runs.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// One artwork variant: three saturated anchor colors.
class _Variant {
  const _Variant(this.dominant, this.lift, this.deep);

  final Color dominant; // The gradient's main hue.
  final Color lift; // The upper radial glow.
  final Color deep; // The lower glow / fade colour.

  int get domR => (dominant.r * 255.0).round();
  int get domG => (dominant.g * 255.0).round();
  int get domB => (dominant.b * 255.0).round();

  int get liftR => (lift.r * 255.0).round();
  int get liftG => (lift.g * 255.0).round();
  int get liftB => (lift.b * 255.0).round();

  int get deepR => (deep.r * 255.0).round();
  int get deepG => (deep.g * 255.0).round();
  int get deepB => (deep.b * 255.0).round();
}

/// Six distinct, saturated palettes — separated enough that adjacent fixtures
/// produce clearly different ambient washes.
const List<_Variant> _variants = <_Variant>[
  _Variant(Color(0xFF6D3AE8), Color(0xFFB96DFF), Color(0xFF2A1245)), // plum
  _Variant(Color(0xFFE8573A), Color(0xFFFFB35C), Color(0xFF5C1408)), // ember
  _Variant(Color(0xFF149CD1), Color(0xFF5AE0C8), Color(0xFF0A3055)), // lagoon
  _Variant(Color(0xFF3FAE5C), Color(0xFFB8E986), Color(0xFF12361E)), // moss
  _Variant(Color(0xFFE43A78), Color(0xFFFF9AD5), Color(0xFF4A0F2B)), // rose
  _Variant(Color(0xFFD9A621), Color(0xFFF7E8A4), Color(0xFF4A330A)), // gold
];

/// Size of the generated art (RGBA pixels). Squares, so every tile crops clean.
const int _artResolution = 256;

final Map<int, Future<ui.Image>> _imageCache = <int, Future<ui.Image>>{};

/// Images that finished decoding during warm-up. Reading these is
/// synchronous, which is what the completer path needs: awaiting the
/// decode *future* from inside the FakeAsync test zone suspends until the
/// real event loop runs again, long after the golden was captured.
final Map<int, ui.Image> _readyImages = <int, ui.Image>{};

/// The three palette colors a fixture URL lifts for the ambient backdrop.
List<Color> sampleArtworkColors(String? url) {
  final _Variant variant = _variantFor(url);
  return <Color>[variant.dominant, variant.lift, variant.deep];
}

/// Resolve the variant a URL encodes. Stable per URL, varied across the set.
_Variant _variantFor(String? url) {
  if (url == null || url.isEmpty) return _variants.first;
  final int hash = url.hashCode.abs();
  return _variants[hash % _variants.length];
}

/// The [ImageProvider] the resolver returns for fixture URLs.
///
/// The gradient is generated lazily per variant (decoded with
/// `decodeImageFromPixels`, exactly like the seeded grain fixture) and
/// shared, so six decodes cover the whole fixture corpus.
class SampleArtworkImage extends ImageProvider<SampleArtworkKey> {
  const SampleArtworkImage({required this.variant});

  /// Which gradient variant to paint.
  final int variant;

  @override
  Future<SampleArtworkKey> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<SampleArtworkKey>(SampleArtworkKey(variant));
  }

  @override
  ImageStreamCompleter loadImage(
    SampleArtworkKey key,
    ImageDecoderCallback decode,
  ) {
    // Warm path: the decoded [ui.Image] is straight to hand, synchronously.
    // ImageStreamCompleter replays a set image to late listeners, so the
    // widget paints the art on the very frame it first builds.
    if (_readyImages[key.variant] case final ui.Image image) {
      return OneFrameImageStreamCompleter(
        SynchronousFuture<ImageInfo>(ImageInfo(image: image)),
      );
    }
    // Fallback for pumps that bypass warm-up: the async path, with one hop
    // so the notification never fires inside the resolve chain itself.
    return OneFrameImageStreamCompleter(_resolve(key));
  }

  /// Fallback for pumps that bypass warm-up: the async decode path. Still
  /// routed through the same cache, so a later warm run finds it ready.
  Future<ImageInfo> _resolve(SampleArtworkKey key) async {
    final ui.Image image = await _imageFor(key.variant);
    return ImageInfo(image: image);
  }
}

/// Identity for [SampleArtworkImage] so Flutter can match resolves to
/// completers across tiles and golden captures.
@immutable
class SampleArtworkKey {
  const SampleArtworkKey(this.variant);

  final int variant;

  @override
  bool operator ==(Object other) =>
      other is SampleArtworkKey && other.variant == variant;

  @override
  int get hashCode => variant.hashCode;
}

/// Decoded-image cache, keyed by variant.
Future<ui.Image> _imageFor(int variant) {
  final int safe = variant.abs() % _variants.length;
  return _imageCache.putIfAbsent(safe, () => _decode(safe));
}

/// Pre-decodes every variant so widget tests and goldens never race the
/// image pipeline. Call it inside `WidgetTester.runAsync` before pumping —
/// the decode finishes on the real event loop, outside the fake-clock zone,
/// and the results land in the synchronous map [loadImage] reads.
Future<void> warmSampleArtwork() async {
  final List<Future<void>> pending = <Future<void>>[
    for (int i = 0; i < _variants.length; i++)
      _imageFor(i).then((ui.Image image) => _readyImages[i] = image),
  ];
  await Future.wait(pending);
}

/// Build the RGBA pixel buffer and hand it to the platform decoder.
Future<ui.Image> _decode(int variantIndex) {
  final Uint8List raw = _pixelsFor(_variants[variantIndex]);

  final Completer<ui.Image> done = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    raw,
    _artResolution,
    _artResolution,
    ui.PixelFormat.rgba8888,
    done.complete,
  );
  return done.future;
}

/// Channel-wise 8-bit linear interpolation in normalized space.
_Color _lerpRgb(int r1, int g1, int b1, int r2, int g2, int b2, double t) {
  return _Color(
    (r1 + (r2 - r1) * t).round(),
    (g1 + (g2 - g1) * t).round(),
    (b1 + (b2 - b1) * t).round(),
  );
}

/// Just the three channels of an 8-bit color.
class _Color {
  const _Color(this.r, this.g, this.b);

  final int r;
  final int g;
  final int b;
}

/// Paint one variant's pixels in pure dart:math — a vertical ramp of the
/// dominant hue, two radial glows (lift upper-left, deep lower-right), a soft
/// bright ring for structure, and seeded per-pixel grain so gradients do not
/// band under blur.
Uint8List _pixelsFor(_Variant variant) {
  final int size = _artResolution;
  final Uint8List raw = Uint8List(size * size * 4);
  final math.Random noise = math.Random(variant.dominant.toARGB32());

  for (int py = 0; py < size; py++) {
    for (int px = 0; px < size; px++) {
      final double x = px / (size - 1);
      final double y = py / (size - 1);

      // Vertical base ramp: dominant up top, deep at the bottom.
      final _Color base = _lerpRgb(
          variant.domR, variant.domG, variant.domB,
          variant.deepR, variant.deepG, variant.deepB, y);

      // Radial glow of the lift color, upper-left, fairly wide.
      final double liftDist =
          math.sqrt(math.pow(x - 0.28, 2) + math.pow(y - 0.24, 2)) / 0.75;
      final double liftMix = (1 - liftDist.clamp(0.0, 1.0)) * 0.65;

      // Radial glow of the deep color, lower-right, softly expanding.
      final double deepDist =
          math.sqrt(math.pow(x - 0.72, 2) + math.pow(y - 0.78, 2)) / 0.85;
      final double deepMix = (1 - deepDist.clamp(0.0, 1.0)) * 0.45;

      // A subtle bright ring for structure: album covers hold a shape, and a
      // blur should find circled light where the eye expects it.
      final double ringDist =
          (math.sqrt(math.pow(x - 0.5, 2) + math.pow(y - 0.5, 2)) - 0.34)
              .abs();
      final double ringMix = (1 - (ringDist / 0.055).clamp(0.0, 1.0)) * 0.14;

      int r = base.r;
      int g = base.g;
      int b = base.b;

      r += ((variant.liftR - r) * liftMix).round();
      g += ((variant.liftG - g) * liftMix).round();
      b += ((variant.liftB - b) * liftMix).round();

      r += ((variant.deepR - r) * deepMix).round();
      g += ((variant.deepG - g) * deepMix).round();
      b += ((variant.deepB - b) * deepMix).round();

      // The ring lifts toward the lift hue.
      r += ((variant.liftR - r) * ringMix).round();
      g += ((variant.liftG - g) * ringMix).round();
      b += ((variant.liftB - b) * ringMix).round();

      // Seeded film grain, ±7 on every channel.
      final int dither = noise.nextInt(15) - 7;
      r = (r + dither).clamp(0, 255);
      g = (g + dither).clamp(0, 255);
      b = (b + dither).clamp(0, 255);

      final int offset = (py * size + px) * 4;
      raw[offset] = r;
      raw[offset + 1] = g;
      raw[offset + 2] = b;
      raw[offset + 3] = 255; // Album art is opaque.
    }
  }
  return raw;
}

/// The artwork resolver the harness installs: every fixture URL becomes one
/// of the six gradient variants, never a network image.
SampleArtworkImage? sampleArtworkResolver(String? url) {
  if (url == null || url.isEmpty) return null;
  return SampleArtworkImage(
    variant: _variants.indexOf(_variantFor(url)),
  );
}
