import 'package:flutter/foundation.dart';

/// How a track was left.
///
/// These are the sidecar's own three values (`ListeningEventIn.outcome`), so
/// the wire format is not a second vocabulary invented here.
enum ListeningOutcome {
  /// The media reached its end.
  completed,

  /// The listener moved to another track first.
  skipped,

  /// Playback stopped for another reason: the queue was cleared, the app was
  /// closed, or the stream failed.
  stopped;

  String get wireName => name;
}

/// One aggregated playback event, sent when a track is left.
///
/// Deliberately not a position tick: it carries what was actually listened to
/// and how the track ended, which is all the sidecar's store keeps. No session
/// value, stream URL or free-text field belongs here — the store is a ranking
/// signal, not a transcript of the session.
@immutable
class ListeningEvent {
  const ListeningEvent({
    required this.videoId,
    required this.outcome,
    this.title,
    this.artist,
    this.source,
    this.startedAt,
    this.listenedSeconds = 0,
    this.durationSeconds = 0,
  });

  final String videoId;
  final ListeningOutcome outcome;
  final String? title;
  final String? artist;

  /// Where the track was started from, e.g. `library` or `search`. Optional:
  /// the sidecar stores what it is given and nothing depends on it.
  final String? source;

  /// Epoch seconds, when the app knows them.
  final double? startedAt;

  /// Seconds actually played, clamped by the sidecar again on the way in.
  final double listenedSeconds;

  /// The track's own length, or 0 when the service did not say.
  final double durationSeconds;

  /// The sidecar's `/listening/events` body. Optional fields are omitted
  /// rather than sent as nulls.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'videoId': videoId,
        'outcome': outcome.wireName,
        if (title != null && title!.isNotEmpty) 'title': title,
        if (artist != null && artist!.isNotEmpty) 'artist': artist,
        if (source != null && source!.isNotEmpty) 'source': source,
        if (startedAt != null) 'startedAt': startedAt,
        'listenedSeconds': listenedSeconds,
        'durationSeconds': durationSeconds,
      };

  @override
  bool operator ==(Object other) =>
      other is ListeningEvent &&
      other.videoId == videoId &&
      other.outcome == outcome &&
      other.title == title &&
      other.artist == artist &&
      other.source == source &&
      other.startedAt == startedAt &&
      other.listenedSeconds == listenedSeconds &&
      other.durationSeconds == durationSeconds;

  @override
  int get hashCode => Object.hash(
        videoId,
        outcome,
        title,
        artist,
        source,
        startedAt,
        listenedSeconds,
        durationSeconds,
      );
}
