import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../audio/playback_controller.dart';
import '../../audio/playback_state.dart';
import '../../theme/icons.dart';
import '../../theme/tokens.dart';
import '../../ui/glass_surface.dart';
import '../../ui/pressable.dart';

/// The floating transport pill.
///
/// Spec: glass with the specular streak, shuffle / previous / play-pause / next
/// / repeat. Every control reflects real playback state; the play button is
/// white with a dark glyph, and active toggles gain full-white foregrounds.
class TransportPill extends ConsumerWidget {
  const TransportPill({super.key});

  /// What the pill needs at minimum: five 48px controls plus its own
  /// horizontal padding. Parents shrinking around it — like the player
  /// column that follows the artwork's width — must not go below this.
  static const double minWidth = Tokens.minTouchTarget * 5 + Tokens.s16 * 2;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlaybackState state = ref.watch(playbackProvider);
    final PlaybackController controller = ref.read(playbackProvider.notifier);

    return GlassSurface(
      tier: GlassTier.thick,
      shape: Tokens.shapePill,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Tokens.s16,
          vertical: Tokens.s8,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Pressable(
              onTap: () => controller.setShuffle(!state.shuffle),
              semanticLabel: 'Shuffle',
              child: Icon(
                AppIcons.shuffle,
                size: Tokens.iconSize,
                color: state.shuffle ? Tokens.text : Tokens.textSecondary,
              ),
            ),
            Pressable(
              onTap: controller.previous,
              semanticLabel: 'Previous',
              child: const Icon(
                AppIcons.skipBack,
                size: Tokens.iconSize,
                color: Tokens.text,
              ),
            ),
            Pressable(
              onTap: controller.togglePlayPause,
              semanticLabel: state.isPlaying ? 'Pause' : 'Play',
              child: SizedBox(
                width: Tokens.minTouchTarget,
                height: Tokens.minTouchTarget,
                child: DecoratedBox(
                  decoration: const ShapeDecoration(
                    color: Tokens.text,
                    shape: Tokens.shapePill,
                  ),
                  child: Icon(
                    state.isPlaying ? AppIcons.pauseFill : AppIcons.playFill,
                    size: Tokens.iconSize,
                    color: Tokens.bg,
                  ),
                ),
              ),
            ),
            Pressable(
              onTap: controller.next,
              semanticLabel: 'Next',
              child: const Icon(
                AppIcons.skipForward,
                size: Tokens.iconSize,
                color: Tokens.text,
              ),
            ),
            Pressable(
              onTap: controller.cycleRepeat,
              semanticLabel: 'Repeat',
              child: Icon(
                AppIcons.repeat,
                size: Tokens.iconSize,
                color: state.repeat.isActive
                    ? Tokens.text
                    : Tokens.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
