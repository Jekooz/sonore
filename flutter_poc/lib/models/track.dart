/// One playable track.
///
/// Field mapping mirrors the shipped WinUI model
/// (`frontend/Services/ApiClient.cs`, `SearchResultGroup`): ytmusicapi puts the
/// credit line in `artists[]` for songs/videos, `artist` for albums and
/// `author` for playlists.
class Track {
  const Track({required this.videoId, required this.title, required this.artist});

  final String videoId;
  final String title;
  final String artist;

  /// Returns null for result types with no playable id (albums, artists,
  /// playlists): the POC must not invent a track for them.
  static Track? fromSearchResult(Map<String, dynamic> json) {
    final id = json['videoId'] as String?;
    if (id == null || id.isEmpty) return null;

    final artists = (json['artists'] as List<dynamic>? ?? const <dynamic>[])
        .map((a) => (a as Map<String, dynamic>)['name'] as String? ?? '')
        .where((n) => n.isNotEmpty)
        .toList(growable: false);
    final artist = (json['artist'] as String?) ??
        (artists.isNotEmpty ? artists.join(', ') : (json['author'] as String? ?? ''));

    return Track(
      videoId: id,
      title: (json['title'] as String?) ?? 'Unknown title',
      artist: artist,
    );
  }

  Map<String, dynamic> toJson() => {'videoId': videoId, 'title': title, 'artist': artist};

  static Track fromJson(Map<String, dynamic> json) => Track(
        videoId: json['videoId'] as String,
        title: json['title'] as String,
        artist: json['artist'] as String? ?? '',
      );
}
