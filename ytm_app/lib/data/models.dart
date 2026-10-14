import 'package:flutter/foundation.dart';

import '../audio/track.dart';

/// Which collection a row or card opens.
enum CollectionKind {
  album('/album'),
  playlist('/playlist'),
  artist('/artist');

  const CollectionKind(this.pathPrefix);

  /// The sidecar endpoint prefix this kind is fetched from.
  final String pathPrefix;

  static CollectionKind? byName(String name) {
    for (final CollectionKind kind in CollectionKind.values) {
      if (kind.name == name) return kind;
    }
    return null;
  }
}

/// A reference to an album, playlist or artist page.
@immutable
class CollectionRef {
  const CollectionRef(this.kind, this.id);

  final CollectionKind kind;
  final String id;

  /// The in-app route for this page.
  ///
  /// Collection pages are a shell branch of their own, so opening one keeps the
  /// adaptive navigation and the mini player in place (see `routing/`).
  String get routePath => '/collection/${kind.name}/${Uri.encodeComponent(id)}';

  /// Parses the branch's two path segments, or null when either is unknown.
  static CollectionRef? fromRoute(String? kindName, String? id) {
    if (kindName == null || id == null || id.isEmpty) return null;
    final CollectionKind? kind = CollectionKind.byName(kindName);
    return kind == null ? null : CollectionRef(kind, id);
  }

  @override
  bool operator ==(Object other) =>
      other is CollectionRef && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

/// The kind of a row, which decides what the row can actually do.
enum MediaKind {
  song,
  video,
  episode,
  album,
  artist,
  playlist;

  /// Label shown when the kind is worth surfacing (anything but a plain song).
  String? get badge => switch (this) {
        MediaKind.song => null,
        MediaKind.video => 'Video',
        MediaKind.episode => 'Episode',
        MediaKind.album => 'Album',
        MediaKind.artist => 'Artist',
        MediaKind.playlist => 'Playlist',
      };
}

/// One row or card from the music service, in a shape every screen can render.
///
/// A [MediaItem] is only ever built when it has something real to do: either
/// [track] (it is playable) or [collection] (it opens a page). Parsers return
/// null otherwise, so nothing renders a row that cannot act.
@immutable
class MediaItem {
  const MediaItem({
    required this.kind,
    required this.title,
    this.subtitle = '',
    this.artworkUrl,
    this.track,
    this.collection,
  });

  final MediaKind kind;
  final String title;
  final String subtitle;
  final String? artworkUrl;

  /// Set when the item is directly playable.
  final Track? track;

  /// Set when the item opens a collection page.
  final CollectionRef? collection;

  bool get isPlayable => track != null;

  @override
  bool operator ==(Object other) =>
      other is MediaItem &&
      other.kind == kind &&
      other.title == title &&
      other.subtitle == subtitle &&
      other.artworkUrl == artworkUrl &&
      other.track == track &&
      other.collection == collection;

  @override
  int get hashCode =>
      Object.hash(kind, title, subtitle, artworkUrl, track, collection);
}

/// One Home rail. Rows the sidecar returns empty are dropped before this is
/// built, so a rail always has at least one card.
@immutable
class HomeRow {
  const HomeRow({required this.title, required this.items});

  final String title;
  final List<MediaItem> items;
}

/// Search results grouped as the spec requires: Songs, Albums, Artists and
/// Playlists.
@immutable
class SearchResults {
  const SearchResults({
    this.songs = const <MediaItem>[],
    this.albums = const <MediaItem>[],
    this.artists = const <MediaItem>[],
    this.playlists = const <MediaItem>[],
    this.query = '',
  });

  final List<MediaItem> songs;
  final List<MediaItem> albums;
  final List<MediaItem> artists;
  final List<MediaItem> playlists;

  /// The query these results belong to, so the empty state can name it.
  final String query;

  bool get isEmpty =>
      songs.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty;

  int get length =>
      songs.length + albums.length + artists.length + playlists.length;
}

/// An album, playlist or artist page: a header plus its tracks.
@immutable
class Collection {
  const Collection({
    required this.ref,
    required this.title,
    this.subtitle = '',
    this.artworkUrl,
    this.tracks = const <MediaItem>[],
  });

  final CollectionRef ref;
  final String title;
  final String subtitle;
  final String? artworkUrl;
  final List<MediaItem> tracks;

  /// Tracks that can actually be played, in order — what Play on this page
  /// queues.
  List<Track> get playableTracks =>
      tracks.map((MediaItem item) => item.track).whereType<Track>().toList();
}

/// The library's segments (spec: Playlists, Songs, Albums, Artists), plus the
/// liked-songs endpoint the sidecar already exposes.
enum LibrarySegment {
  playlists('playlists', 'Playlists'),
  songs('songs', 'Songs'),
  albums('albums', 'Albums'),
  artists('artists', 'Artists'),
  liked('liked', 'Liked'),

  /// What this app itself played, newest first (design.md's Library →
  /// Listening History). Its payload is an object, not a list of service rows,
  /// so the repository reads it through its own endpoint.
  history('listening/history', 'History');

  const LibrarySegment(this.endpoint, this.label);

  final String endpoint;
  final String label;
}

// ---------------------------------------------------------------- parsing ---

/// Parses one row into a [MediaItem], or null when it has no real target.
///
/// The order of checks matters and mirrors the payloads the sidecar actually
/// returns: a Home song card carries both a `videoId` and a radio `playlistId`,
/// so playability is decided before any collection id is considered.
MediaItem? mediaItemFrom(Map<String, dynamic> json) {
  final String title = _titleOf(json);
  if (title.isEmpty) return null;

  final String? videoId = _nonEmpty(json['videoId']);
  final String artists = _performers(json);
  final String? artworkUrl = largestThumbnail(json);
  final String resultType = (json['resultType'] as String? ?? '').toLowerCase();
  final String? typeLabel = _nonEmpty(json['type']);

  if (videoId != null) {
    final MediaKind kind = switch (resultType) {
      'video' => MediaKind.video,
      'episode' => MediaKind.episode,
      _ => MediaKind.song,
    };
    final MediaItem item = MediaItem(
      kind: kind,
      title: title,
      subtitle: _defaultSubtitle(json, artists),
      artworkUrl: artworkUrl,
      track: Track(
        id: videoId,
        title: title,
        artist: artists.isEmpty ? 'Unknown artist' : artists,
        album: _albumName(json),
        albumId: _albumId(json),
        artistId: _firstArtistId(json),
        duration: durationOf(json),
        artworkUrl: artworkUrl,
        isLiked: isLiked(json),
      ),
    );
    return item;
  }

  final CollectionRef? collection = collectionOf(json);
  if (collection == null) return null;

  // An artist card's credit line is the subscriber count; an album's is the
  // type (Album/Single/EP) and its performers; a playlist's is its author.
  final String subtitle = switch (collection.kind) {
    // An artist row's *name* is in `artist`, so its credit line is the
    // subscriber count — repeating the name there would say nothing.
    CollectionKind.artist => _nonEmpty(json['subscribers']) ?? '',
    CollectionKind.album => <String>[
        ?typeLabel,
        if (artists.isNotEmpty) artists,
      ].join(' · '),
    // A playlist row often has no author ("Liked Music" is authored by nobody
    // and described as "Auto playlist"), so fall back to its description.
    CollectionKind.playlist => artists.isNotEmpty
        ? artists
        : (_nonEmpty(json['description']) ??
            _nonEmpty(json['itemCount']) ??
            ''),
  };

  final MediaKind kind = switch (collection.kind) {
    CollectionKind.album => MediaKind.album,
    CollectionKind.artist => MediaKind.artist,
    CollectionKind.playlist => MediaKind.playlist,
  };

  return MediaItem(
    kind: kind,
    title: title,
    subtitle: subtitle,
    artworkUrl: artworkUrl,
    collection: collection,
  );
}

/// The collection a row or card points at, or null when it points at nothing
/// that can be opened.
CollectionRef? collectionOf(Map<String, dynamic> json) {
  final String browseId = _nonEmpty(json['browseId']) ?? '';

  if (browseId.startsWith('MPREb')) {
    return CollectionRef(CollectionKind.album, browseId);
  }
  // A playlist search row exposes its id as `VL<playlistId>` and carries no
  // separate playlistId field.
  if (browseId.startsWith('VL') && browseId.length > 2) {
    return CollectionRef(CollectionKind.playlist, browseId.substring(2));
  }
  if (browseId.startsWith('UC') || browseId.startsWith('MPLAUC')) {
    return CollectionRef(CollectionKind.artist, browseId);
  }

  final String? playlistId = _nonEmpty(json['playlistId']);
  if (playlistId != null) {
    return CollectionRef(CollectionKind.playlist, playlistId);
  }

  // Podcast shows and other pages the app has no screen for: no row is built,
  // rather than a row that does nothing.
  return null;
}

/// The largest thumbnail the service offered, which is the one worth caching.
String? largestThumbnail(Map<String, dynamic> json) {
  final dynamic thumbnails = json['thumbnails'];
  if (thumbnails is! List<dynamic> || thumbnails.isEmpty) return null;

  Map<String, dynamic>? best;
  int bestWidth = -1;
  for (final dynamic entry in thumbnails) {
    if (entry is! Map<String, dynamic>) continue;
    final String? url = _nonEmpty(entry['url']);
    if (url == null) continue;
    final int width = (entry['width'] as num?)?.toInt() ?? 0;
    if (width >= bestWidth) {
      bestWidth = width;
      best = entry;
    }
  }
  return best == null ? null : _nonEmpty(best['url']);
}

/// The row's name.
///
/// Every row carries `title` except an artist row, which puts its name in
/// `artist` (the real payload is `{"artist": "Seedhe Maut", "browseId":"MPLAUC…"}`).
/// Without this an artist row parsed to nothing and disappeared from Library
/// and Search.
String _titleOf(Map<String, dynamic> json) =>
    _nonEmpty(json['title']) ?? _nonEmpty(json['artist']) ?? '';

/// Who gets credit for this row.
///
/// ytmusicapi is inconsistent: songs, videos and albums put performers in
/// `artists[]`, playlists use `author`, and podcast episodes name their show
/// under `podcast`. An artist row has no separate credit line — its name is the
/// title — so this returns empty for one rather than echoing the name.
String _performers(Map<String, dynamic> json) {
  final dynamic artists = json['artists'];
  if (artists is List<dynamic> && artists.isNotEmpty) {
    final List<String> names = <String>[];
    for (final dynamic entry in artists) {
      if (entry is Map<String, dynamic>) {
        final String? name = _nonEmpty(entry['name']);
        if (name != null) names.add(name);
      } else if (entry is String && entry.trim().isNotEmpty) {
        names.add(entry.trim());
      }
    }
    if (names.isNotEmpty) return names.join(', ');
  }

  final String? author = _nonEmpty(json['author']);
  if (author != null) return author;

  final dynamic podcast = json['podcast'];
  if (podcast is Map<String, dynamic>) {
    return _nonEmpty(podcast['name']) ?? '';
  }
  return '';
}

String _defaultSubtitle(Map<String, dynamic> json, String artists) {
  final String badge = switch ((json['resultType'] as String? ?? '').toLowerCase()) {
    'video' => 'Video',
    'episode' => 'Episode',
    _ => '',
  };
  if (badge.isEmpty) return artists;
  return artists.isEmpty ? badge : '$badge · $artists';
}

/// Duration from the service: `duration_seconds` when present, otherwise the
/// `m:ss` string. Null when the service does not know, so seeking stays
/// disabled rather than being faked.
Duration? durationOf(Map<String, dynamic> json) {
  final dynamic seconds = json['duration_seconds'];
  if (seconds is num && seconds > 0) {
    return Duration(seconds: seconds.toInt());
  }
  final String? text = _nonEmpty(json['duration']);
  if (text == null) return null;
  final List<String> parts = text.split(':');
  if (parts.isEmpty || parts.length > 3) return null;
  int total = 0;
  for (final String part in parts) {
    final int? value = int.tryParse(part.trim());
    if (value == null) return null;
    total = total * 60 + value;
  }
  return total > 0 ? Duration(seconds: total) : null;
}

/// The album name, from either shape the service uses: an object
/// `{name, id}` or a bare string (as `get_album()` returns).
String? _albumName(Map<String, dynamic> json) {
  final dynamic album = json['album'];
  if (album is Map<String, dynamic>) return _nonEmpty(album['name']);
  if (album is String) return _nonEmpty(album);
  return null;
}

/// The album's browse id, when the service sent one.
///
/// `get_album()` normalizes its tracks to `{name:…, id:null}`, so an id is
/// often absent; when it is, the context menu offers no "Go to album" rather
/// than a link that would open nothing.
String? _albumId(Map<String, dynamic> json) {
  final dynamic album = json['album'];
  if (album is Map<String, dynamic>) return _nonEmpty(album['id']);
  return null;
}

/// The first credited artist's channel id, when the service sent one.
String? _firstArtistId(Map<String, dynamic> json) {
  final dynamic artists = json['artists'];
  if (artists is List<dynamic> && artists.isNotEmpty) {
    final dynamic first = artists.first;
    if (first is Map<String, dynamic>) return _nonEmpty(first['id']);
  }
  return null;
}

/// Real persisted like state, not a temporary visual toggle.
bool isLiked(Map<String, dynamic> json) {
  final String? status = _nonEmpty(json['likeStatus']);
  return status?.toUpperCase() == 'LIKE';
}

String? _nonEmpty(dynamic value) {
  if (value == null) return null;
  final String text = value.toString().trim();
  return text.isEmpty ? null : text;
}

// ----------------------------- lyrics -----------------------------

/// One line of lyrics.
///
/// [start] and [end] are null when the provider supplied no timing, which is
/// what keeps static lyrics honest: the client never invents a timestamp.
@immutable
class LyricsLine {
  const LyricsLine({required this.text, this.start, this.end});

  final String text;
  final Duration? start;
  final Duration? end;

  bool get isTimed => start != null;
}

/// Real lyrics for one track, exactly as the sidecar's `/lyrics/{video_id}`
/// resolved them. Never parsed from anywhere else.
@immutable
class LyricsResult {
  const LyricsResult({
    required this.lines,
    required this.synced,
    this.source,
  });

  /// True only when the provider genuinely supplied timings, so the screen can
  /// offer auto-scroll and seek-to-line — and must not when this is false.
  final bool synced;

  final List<LyricsLine> lines;

  /// Attribution the provider sent (e.g. "Source: Musixmatch").
  final String? source;

  bool get isEmpty => lines.isEmpty;

  factory LyricsResult.fromJson(Map<String, dynamic> json) {
    final List<LyricsLine> lines = <LyricsLine>[];
    final List<dynamic> rows =
        json['lines'] is List<dynamic> ? json['lines']! as List<dynamic> : const <dynamic>[];
    for (final dynamic row in rows) {
      if (row is! Map<String, dynamic>) continue;
      final String? text = _nonEmpty(row['text']);
      if (text == null) continue;
      final int startMs = row['startMs'] is int ? row['startMs']! as int : 0;
      final int endMs = row['endMs'] is int ? row['endMs']! as int : 0;
      lines.add(
        LyricsLine(
          text: text,
          start: row['startMs'] is int ? Duration(milliseconds: startMs) : null,
          end: row['endMs'] is int ? Duration(milliseconds: endMs) : null,
        ),
      );
    }
    return LyricsResult(
      lines: lines,
      synced: json['synced'] == true,
      source: _nonEmpty(json['source']),
    );
  }
}
