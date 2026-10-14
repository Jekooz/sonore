import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:palette_generator/palette_generator.dart';

import '../../theme/tokens.dart';

/// Turns a track's artwork URL into an [ImageProvider], or null when the track
/// has no artwork.
///
/// This is a seam: the app resolves remote artwork through the cache, and tests
/// override it to null so a golden never touches the network.
typedef ArtworkResolver = ImageProvider? Function(String? url);

final Provider<ArtworkResolver> artworkResolverProvider =
    Provider<ArtworkResolver>((ref) => _networkArtwork);

ImageProvider? _networkArtwork(String? url) =>
    url == null || url.isEmpty ? null : CachedNetworkImageProvider(url);

/// Lifts 2-3 colors out of the current artwork for the ambient background.
///
/// Overridden in tests with fixed colors so the ambient render is deterministic.
typedef AmbientPaletteLoader = Future<List<Color>> Function(String url);

final Provider<AmbientPaletteLoader> ambientPaletteLoaderProvider =
    Provider<AmbientPaletteLoader>((ref) => _loadAmbientPalette);

Future<List<Color>> _loadAmbientPalette(String url) async {
  final PaletteGenerator generator = await PaletteGenerator.fromImageProvider(
    CachedNetworkImageProvider(url),
    maximumColorCount: Tokens.ambientColorCount,
  );
  return generator.paletteColors
      .take(Tokens.ambientColorCount)
      .map((PaletteColor entry) => entry.color)
      .toList(growable: false);
}

/// The artwork-driven ambient wash behind Now Playing.
///
/// Color here comes only from the current artwork (spec: principle 4): the
/// colors are drawn as blurred radial gradients at [Tokens.ambientOpacity] with
/// a black overlay on top for legibility. An empty list renders plain black.
class AmbientBackground extends StatelessWidget {
  const AmbientBackground({super.key, required this.colors});

  final List<Color> colors;

  /// Blob placement, the same for every palette so the wash is stable between
  /// tracks. Geometry, not design tokens.
  static const List<Alignment> _placements = <Alignment>[
    Alignment(-0.65, -0.6),
    Alignment(0.7, -0.1),
    Alignment(-0.1, 0.85),
  ];

  @override
  Widget build(BuildContext context) {
    if (colors.isEmpty) {
      return const ColoredBox(color: Tokens.bg);
    }

    final double extent = MediaQuery.sizeOf(context).shortestSide;

    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          const ColoredBox(color: Tokens.bg),
          Opacity(
            opacity: Tokens.ambientOpacity,
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(
                sigmaX: Tokens.ambientBlur,
                sigmaY: Tokens.ambientBlur,
              ),
              child: Stack(
                children: <Widget>[
                  for (int i = 0; i < colors.length; i++)
                    Align(
                      alignment: _placements[i % _placements.length],
                      child: Container(
                        width: extent,
                        height: extent,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: <Color>[colors[i], Tokens.transparent],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const ColoredBox(color: Tokens.ambientOverlay),
        ],
      ),
    );
  }
}
