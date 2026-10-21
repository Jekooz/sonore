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

/// Lifts 2-3 colors out of the current artwork for the ambient backdrop.
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
