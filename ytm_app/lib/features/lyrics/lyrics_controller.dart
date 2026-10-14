import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../audio/playback_controller.dart';
import '../../audio/playback_state.dart';
import '../../audio/track.dart';
import '../../data/models.dart';
import '../../data/ytm_repository.dart';

/// Real lyrics for whatever is playing, straight from the sidecar.
///
/// `null` means the service has no lyrics for this track, which is an answer
/// and not a failure — the screen says so plainly instead of showing an error.
/// Changing track refetches, so the screen never shows the previous song's
/// words over the next song.
final FutureProvider<LyricsResult?> lyricsProvider =
    FutureProvider<LyricsResult?>((Ref ref) async {
  final Track? track = ref.watch(
    playbackProvider.select((PlaybackState state) => state.current),
  );
  if (track == null) return null;
  return ref.watch(ytmRepositoryProvider).lyrics(track);
});
