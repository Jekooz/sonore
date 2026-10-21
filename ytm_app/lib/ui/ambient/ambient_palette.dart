import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../audio/playback_controller.dart';
import '../../audio/playback_state.dart';
import '../../features/now_playing/artwork.dart';

/// The ambient palette for the whole app, keyed by the current artwork URL.
///
/// One provider owns it because every piece of glass asks for the same thing:
/// the artwork-derived colors the surfaces sit over. The map is a small LRU
/// keyed by URL, so flipping back and forth between two tracks never hits the
/// palette decoder again ([Tokens]-budgeted work per track, not per frame).
class AmbientPaletteState {
  const AmbientPaletteState({required this.colors, required this.key});

  /// 2-3 colors lifted from the artwork. Empty when idle or while the lift is
  /// in flight; the backdrop renders its neutral ramp in both cases.
  final List<Color> colors;

  /// The artwork URL these colors belong to. The backdrop uses it as a stable
  /// cross-fade key, so a palette swap fades and a scroll does not.
  final String key;
}

class AmbientPaletteNotifier extends Notifier<AmbientPaletteState> {
  /// Deterministic per-URL colors. Session-wide cache with a small cap; a
  /// music session rarely exceeds this between gallery reloads.
  final Map<String, List<Color>> _cache = <String, List<Color>>{};

  static const int cacheCapacity = 24;

  @override
  AmbientPaletteState build() {
    final String? url = ref.watch(
      playbackProvider.select((PlaybackState state) => state.current?.artworkUrl),
    );

    if (url == null || url.isEmpty) {
      return const AmbientPaletteState(colors: <Color>[], key: '');
    }

    final List<Color>? cached = _cache[url];
    if (cached != null) {
      return AmbientPaletteState(colors: cached, key: url);
    }

    // The lift takes a frame or two; empty colors means the neutral ramp
    // shows meanwhile, and the backdrop cross-fades once this lands. The
    // guard below keeps a slow answer for an old track from writing over the
    // state of the current one.
    final AmbientPaletteLoader loader = ref.watch(ambientPaletteLoaderProvider);
    Future<void>(() async {
      try {
        final List<Color> colors = await loader(url);
        if (_cache.containsKey(url)) return;
        _cache[url] = colors;
        while (_cache.length > cacheCapacity) {
          _cache.remove(_cache.keys.first);
        }
        if (ref.read(playbackProvider).current?.artworkUrl == url) {
          state = AmbientPaletteState(colors: colors, key: url);
        }
      } catch (_) {
        // A failed lift leaves the neutral ramp; retry happens on the next
        // track, and nothing here is worth crashing a render for.
      }
    });

    return AmbientPaletteState(colors: const <Color>[], key: url);
  }

  /// Drops the cache wholesale — for the reset path in tests.
  void clear() => _cache.clear();
}

final NotifierProvider<AmbientPaletteNotifier, AmbientPaletteState>
    ambientPaletteProvider =
    NotifierProvider<AmbientPaletteNotifier, AmbientPaletteState>(
  AmbientPaletteNotifier.new,
);
