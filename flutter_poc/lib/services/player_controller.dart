import '../models/track.dart';
import 'api_client.dart';
import 'playback_service.dart';
import 'queue_service.dart';

/// Binds the three real services together so both screens share one playback
/// path (design.md section 1: "every song action should use the same playback
/// service and queue").
///
/// Errors come back as a display string rather than being thrown at the widget
/// layer, and nothing sensitive is ever logged: the resolved stream URL is
/// passed straight to the engine and never printed.
class PlayerController {
  PlayerController({
    required this.api,
    required this.queue,
    required this.playback,
  });

  final ApiClient api;
  final QueueService queue;
  final PlaybackService playback;

  /// Loads and starts [track]. Returns null on success, else a short message.
  Future<String?> playTrack(Track track) async {
    try {
      final url = await api.streamUrl(track.videoId);
      await playback.load(url);
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (e) {
      // Network/decode failures surface to the UI; the URL is not included.
      return 'playback failed: ${e.runtimeType}';
    }
  }

  /// Click a search row: that row becomes the queue, starting at that row.
  Future<String?> playFromResults(List<Track> results, int startAt) async {
    queue.replaceAll(results, startAt: startAt);
    final track = queue.current;
    if (track == null) return 'nothing to play';
    return playTrack(track);
  }

  /// Next/previous respect the queue and refuse to invent tracks.
  Future<String?> next() async {
    final track = queue.next();
    if (track == null) return 'End of queue';
    return playTrack(track);
  }

  Future<String?> previous() async {
    final track = queue.previous();
    if (track == null) return 'Start of queue';
    return playTrack(track);
  }

  Future<void> togglePlayPause() => playback.togglePlayPause();

  /// Commits a seek; the service clamps it and refuses when the duration is
  /// unknown (design.md section 3.E).
  Future<void> seek(Duration target) => playback.seek(target);
}
