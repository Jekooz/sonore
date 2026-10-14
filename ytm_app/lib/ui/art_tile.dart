import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../theme/icons.dart';
import '../theme/tokens.dart';

/// Square artwork tile. Album art is the only decoration, so the tile has no
/// border and no card — when there is no image it falls back to a flat
/// [Tokens.surface] placeholder rather than a gray box with a shadow.
///
/// Images are cached and fade in over [Tokens.dFadeIn]; on Android/Windows the
/// fade is disabled when Reduce Motion is on.
class ArtTile extends StatelessWidget {
  const ArtTile({
    super.key,
    required this.size,
    this.url,
    this.image,
    this.radius = Tokens.rSmall,
  });

  final double size;

  /// Corner radius token. rCard and rLarge render as squircles.
  final double radius;

  /// Remote artwork URL, loaded through the cache.
  final String? url;

  /// Pre-resolved provider, e.g. a palette-sampled in-memory image.
  final ImageProvider? image;

  @override
  Widget build(BuildContext context) {
    final bool reduceMotion = MediaQuery.of(context).disableAnimations;
    final OutlinedBorder shape = Tokens.shapeFor(radius);

    final Widget content;
    if (image != null) {
      content = Image(
        image: image!,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      );
    } else if (url != null && url!.isNotEmpty) {
      content = CachedNetworkImage(
        imageUrl: url!,
        fit: BoxFit.cover,
        fadeInDuration: reduceMotion ? Duration.zero : Tokens.dFadeIn,
        placeholder: (_, _) => const _ArtPlaceholder(),
        errorWidget: (_, _, _) => const _ArtPlaceholder(),
      );
    } else {
      content = const _ArtPlaceholder();
    }

    return SizedBox(
      width: size,
      height: size,
      child: ClipPath(
        clipper: ShapeBorderClipper(
          shape: shape,
          textDirection: Directionality.maybeOf(context),
        ),
        child: content,
      ),
    );
  }
}

class _ArtPlaceholder extends StatelessWidget {
  const _ArtPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Tokens.surface,
      child: Center(
        child: Icon(
          AppIcons.image,
          size: Tokens.iconSize,
          color: Tokens.textMuted,
        ),
      ),
    );
  }
}
