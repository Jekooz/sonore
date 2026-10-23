"""
The blender: several candidate streams in, one ranked list out.

The three sources each return candidates in the same shape:

    {
      "videoId": str | None,       # None for a source that only knows a song
      "title": str,
      "artists": [{"name": str, "id": str | None}, ...],
      "album": {...} | None,
      "thumbnails": [...],
      "duration": "3:07" | None,
      "durationSeconds": int | None,
      "inLibrary": bool | None,
      "source": "yt" | "local" | "external",
      "affinity": float,           # this source's own confidence, 0..1-ish
    }

What the sources can and cannot do
----------------------------------
The provider and the local layer both know *video ids*, so the tracks they
return are playable. The outside signals do not: ListenBrainz and Last.fm know
songs and artists, not YouTube Music tracks. So an outside signal is a
*refinement*, never a row of its own:

  * when an outside signal names the same song (normalized artist + title) as
    a playable candidate, that candidate is boosted;
  * when an outside signal names an artist one of the candidates is by, the
    candidates by that artist are boosted a little.

An item that still has no video id after merging is dropped: a recommendation
the app cannot play is not a recommendation.

The rules
---------
  * YouTube Music dominates: its weight is the largest, and an item only the
    provider knows about still gets a real score.
  * Dedupe by video id first, then by normalized artist + title, so the same
    song arriving from two sources is one row.
  * Recently played tracks, explicitly disliked tracks and skipped tracks are
    dropped: the user has already heard (or rejected) them.
  * No artist may fill the list: at most [MAX_PER_ARTIST] tracks per artist,
    unless the pool runs dry — then the cap lifts rather than the list
    staying short.
  * Deterministic: the same inputs always produce the same order.
"""

from __future__ import annotations

import re
import unicodedata
from typing import Iterable

from .config import (
    EXTERNAL_ARTIST_BOOST,
    EXTERNAL_SONG_BOOST,
    MAX_PER_ARTIST,
    SOURCES,
    WEIGHTS,
)

_NON_WORD = re.compile(r"[^a-z0-9]+")


def normalize_text(value: str) -> str:
    """
    A comparable form of a title or artist name.

    Case, accents, punctuation and spacing all go away, so "Sajnaani (Remix)"
    and "sajnaani remix" are the same song, and "Arijit Singh" and
    "arijit singh" are the same artist.
    """
    if not value:
        return ""
    decomposed = unicodedata.normalize("NFKD", value)
    ascii_only = "".join(c for c in decomposed if not unicodedata.combining(c))
    return _NON_WORD.sub(" ", ascii_only.lower()).strip()


def artist_names(candidate: dict) -> list[str]:
    """The artist names of a candidate, in the order they were given."""
    names: list[str] = []
    for artist in candidate.get("artists") or []:
        name = artist.get("name") if isinstance(artist, dict) else str(artist)
        if name:
            names.append(str(name))
    return names


def song_key(candidate: dict) -> str:
    """
    The dedupe key of a song: normalized artist plus normalized title.

    The artist is the first one, because a song's first credit is the one
    the service itself uses when it groups tracks by artist.
    """
    artists = artist_names(candidate)
    artist = normalize_text(artists[0]) if artists else ""
    title = normalize_text(str(candidate.get("title") or ""))
    if not title:
        return ""
    return f"{artist}|{title}"


def _affinity(candidate: dict) -> float:
    try:
        return float(candidate.get("affinity") or 0.0)
    except (TypeError, ValueError):
        return 0.0


def _first_artist_key(candidate: dict) -> str:
    artists = artist_names(candidate)
    return normalize_text(artists[0]) if artists else ""


class _Entry:
    """One merged row: the candidate plus what each source said about it."""

    __slots__ = ("candidate", "source", "scores", "order", "video_id", "song")

    def __init__(self, candidate: dict, source: str, order: int):
        self.candidate = dict(candidate)
        self.source = source
        self.scores: dict[str, float] = {}
        self.order = order
        self.video_id = str(candidate.get("videoId") or "") or None
        self.song = song_key(candidate)


def blend(
    sources: dict[str, list[dict]],
    *,
    limit: int = 12,
    weights: dict[str, float] | None = None,
    exclude: Iterable[str] = (),
    recent: Iterable[str] = (),
    disliked: Iterable[str] = (),
    skipped: Iterable[str] = (),
    max_per_artist: int = MAX_PER_ARTIST,
) -> list[dict]:
    """
    Merge the source streams into one ranked list.

    sources:   {source name: [candidate, ...]}
    exclude:   video ids that must not appear (the queue, the seed)
    recent:    video ids played recently — dropped
    disliked:  video ids skipped early or explicitly disliked — dropped
    skipped:   video ids skipped at any point — dropped
    """
    table = dict(WEIGHTS if weights is None else weights)
    blocked = set(exclude or ())
    blocked.update(recent or ())
    blocked.update(disliked or ())
    blocked.update(skipped or ())

    entries: list[_Entry] = []
    by_video: dict[str, _Entry] = {}
    by_song: dict[str, _Entry] = {}
    by_artist: dict[str, list[_Entry]] = {}

    def _register(entry: _Entry) -> None:
        entries.append(entry)
        if entry.video_id:
            by_video[entry.video_id] = entry
        if entry.song:
            by_song.setdefault(entry.song, entry)
        for name in artist_names(entry.candidate):
            key = normalize_text(name)
            if key:
                by_artist.setdefault(key, []).append(entry)

    def _merge(candidate: dict, source: str) -> _Entry | None:
        video_id = str(candidate.get("videoId") or "") or None
        song = song_key(candidate)

        if video_id and video_id in blocked:
            return None

        entry: _Entry | None = None
        if video_id:
            entry = by_video.get(video_id)
        if entry is None and song:
            entry = by_song.get(song)
        if entry is None:
            entry = _Entry(candidate, source, len(entries))
            _register(entry)
        elif entry.video_id is None and video_id:
            # A source that knows the video id filled a gap left by one that
            # only knew the song: the row becomes playable.
            entry.video_id = video_id
            entry.candidate = dict(candidate)
            by_video[video_id] = entry

        weight = float(table.get(source, 0.0))
        entry.scores[source] = entry.scores.get(source, 0.0) + _affinity(
            candidate
        ) * weight
        if weight > float(table.get(entry.source, 0.0)):
            entry.source = source
        return entry

    # The sources that know video ids first: they are what the list is made of.
    for source in SOURCES:
        if source == "external":
            continue
        for candidate in sources.get(source) or []:
            if isinstance(candidate, dict):
                _merge(candidate, source)

    # The outside signals refine what the other two found.
    for candidate in sources.get("external") or []:
        if not isinstance(candidate, dict):
            continue
        if candidate.get("videoId"):
            # An outside source that somehow knows a video id is a candidate
            # like any other; merge it so it can be scored and returned.
            _merge(candidate, "external")
            continue
        title = normalize_text(str(candidate.get("title") or ""))
        artist_key = _first_artist_key(candidate)
        weight = float(table.get("external", 0.0))

        if title:
            # A hint about a *song*: it says something about that song, and
            # only that song. A hint that matches nothing is dropped.
            matched = by_song.get(song_key(candidate))
            if matched is not None:
                matched.scores["external"] = matched.scores.get(
                    "external", 0.0
                ) + (_affinity(candidate) * weight * EXTERNAL_SONG_BOOST)
            continue

        # A hint about an *artist*: it says something about everything that
        # artist has in the list.
        for entry in by_artist.get(artist_key, []) if artist_key else []:
            entry.scores["external"] = entry.scores.get("external", 0.0) + (
                _affinity(candidate) * weight * EXTERNAL_ARTIST_BOOST
            )

    scored: list[tuple[float, int, dict]] = []
    for entry in entries:
        if not entry.video_id:
            # Nothing knows a video id for this one: the app cannot play it.
            continue
        if entry.video_id in blocked:
            continue
        score = sum(entry.scores.values())
        if score <= 0.0:
            continue
        item = dict(entry.candidate)
        item["videoId"] = entry.video_id
        item["source"] = entry.source
        item["score"] = round(score, 6)
        item["sources"] = sorted(
            source for source, value in entry.scores.items() if value > 0.0
        )
        scored.append((score, entry.order, item))

    # Deterministic: score first, then the order the sources were merged in.
    scored.sort(key=lambda row: (-row[0], row[1]))

    chosen: list[dict] = []
    per_artist: dict[str, int] = {}
    deferred: list[tuple[float, int, dict]] = []

    for score, order, item in scored:
        if len(chosen) >= limit:
            break
        key = _first_artist_key(item)
        if key and per_artist.get(key, 0) >= max_per_artist:
            deferred.append((score, order, item))
            continue
        chosen.append(item)
        if key:
            per_artist[key] = per_artist.get(key, 0) + 1

    # The pool of fresh artists ran dry: fill the rest rather than return a
    # short list.
    for _score, _order, item in deferred:
        if len(chosen) >= limit:
            break
        chosen.append(item)

    return chosen[: max(limit, 0)]
