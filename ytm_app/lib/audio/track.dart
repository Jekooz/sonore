import 'package:flutter/foundation.dart';

/// One playable track.
///
/// This is the domain shape the YouTube Music layer resolves into: Phase 4's
/// repositories fill it from the backend and Phase 5's engine plays it. It holds
/// no UI state, so it can be compared and persisted cheaply.
@immutable
class Track {
  const Track({
    required this.id,
    required this.title,
    required this.artist,
    this.album,
    this.albumId,
    this.artistId,
    this.duration,
    this.artworkUrl,
    this.isLiked = false,
  });

  /// Video id for YouTube Music tracks, browse id for other entities.
  final String id;

  final String title;
  final String artist;
  final String? album;

  /// Album browse id, when the service provided one. The context menu's
  /// "Go to album" appears only when this is real; a null here means the menu
  /// simply does not offer the action rather than offering a dead one.
  final String? albumId;

  /// Channel id of the first credited artist, with the same rule as [albumId].
  final String? artistId;

  /// Null when the provider does not know the duration; seeking is disabled in
  /// that case rather than faked.
  final Duration? duration;

  final String? artworkUrl;

  /// Persisted like state, not a temporary visual toggle.
  final bool isLiked;

  Track copyWith({bool? isLiked}) {
    return Track(
      id: id,
      title: title,
      artist: artist,
      album: album,
      albumId: albumId,
      artistId: artistId,
      duration: duration,
      artworkUrl: artworkUrl,
      isLiked: isLiked ?? this.isLiked,
    );
  }

  /// "Artist · Album" when the album is known, otherwise just the artist.
  String get subtitle => album == null || album!.isEmpty ? artist : '$artist · $album';

  @override
  bool operator ==(Object other) =>
      other is Track &&
      other.id == id &&
      other.title == title &&
      other.artist == artist &&
      other.album == album &&
      other.albumId == albumId &&
      other.artistId == artistId &&
      other.duration == duration &&
      other.artworkUrl == artworkUrl &&
      other.isLiked == isLiked;

  @override
  int get hashCode => Object.hash(
        id,
        title,
        artist,
        album,
        albumId,
        artistId,
        duration,
        artworkUrl,
        isLiked,
      );
}
