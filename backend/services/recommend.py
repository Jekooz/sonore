"""
Provider retrieval for the recommendation engine.

Everything here talks to YouTube Music through the injected ``call`` callable
(the app passes ``ytmusic_service.call``), so tests can substitute a fake
without touching auth. Results are normalized to one candidate shape and
cached briefly, because autoplay must not add a slow round-trip at every
track boundary.

Candidate shape (what the ranker and the API endpoints emit)::

    {
      "videoId": str,
      "title": str,
      "artists": [{"name": str, "id": str|None}, ...],
      "album": {"name": str, "id": str|None} | None,
      "thumbnails": [{"url": str, "width": int, "height": int}, ...],
      "duration": "3:07" | None,
      "durationSeconds": int | None,
      "inLibrary": bool | None,
      "source": "radio" | "related",
    }

Provider methods used (verified against installed ytmusicapi 1.12.3):

  * ``get_watch_playlist(videoId=..., radio=True, limit=...)`` →
    {"tracks": [...], "playlistId": ..., "related": <browseId or None>, ...}
    — the real Start-Radio endpoint. Watch tracks carry ``length`` and a
    singular ``thumbnail`` key, hence the normalization below.
  * ``get_song_related(browseId=related)`` → shelves ("You might also like",
    "Recommended playlists", "Similar artists"); only shelf items with a
    ``videoId`` become song candidates.
  * ``get_history()`` → recently played playlistItems (provider-side
    familiarity for cold start).
  * ``get_liked_songs(limit=...)`` → {"tracks": [...]} liked videoIds.

YouTube Music does not expose its ranking logic; this module only gathers
genuine candidates in provider order — ranking is ranking.rank()'s job.
"""

from __future__ import annotations

import logging
import threading
import time

logger = logging.getLogger("ytmusic-backend")

RADIO_CACHE_TTL = 300      # seconds — radio changes each call, cache briefly
RELATED_CACHE_TTL = 900
FAMILIARITY_CACHE_TTL = 900

_cache: dict[str, tuple[float, object]] = {}
_cache_lock = threading.Lock()


def clear_caches() -> None:
    """Reset every provider cache (tests)."""
    with _cache_lock:
        _cache.clear()


def _cached(key: str, ttl: float, producer):
    now = time.monotonic()
    with _cache_lock:
        hit = _cache.get(key)
        if hit and hit[0] > now:
            return hit[1]
    value = producer()  # outside the lock: never hold it across network I/O
    with _cache_lock:
        _cache[key] = (time.monotonic() + ttl, value)
    return value


# ---------------- normalization ----------------

def _thumbnails(raw, fallback=None) -> list[dict]:
    if isinstance(raw, list) and raw:
        return [t for t in raw if isinstance(t, dict) and t.get("url")]
    return list(fallback or [])


def _artists(raw) -> list[dict]:
    out = []
    if isinstance(raw, list):
        for a in raw:
            if isinstance(a, dict) and a.get("name"):
                out.append({"name": a["name"], "id": a.get("id")})
            elif isinstance(a, str) and a:
                out.append({"name": a, "id": None})
    return out


def _album(raw) -> dict | None:
    if isinstance(raw, dict) and raw.get("name"):
        return {"name": raw["name"], "id": raw.get("id")}
    if isinstance(raw, str) and raw:
        return {"name": raw, "id": None}
    return None


def _seconds(length) -> int | None:
    """\"3:07\" → 187; anything unparseable → None (never raises)."""
    if not isinstance(length, str) or ":" not in length:
        return None
    try:
        parts = [int(p) for p in length.split(":")]
    except ValueError:
        return None
    if not 1 <= len(parts) <= 3:
        return None
    seconds = 0
    for p in parts:
        seconds = seconds * 60 + p
    return seconds


def normalize_candidate(track: dict, source: str) -> dict | None:
    """One watch/related/search track → candidate shape, or None if unusable."""
    if not isinstance(track, dict):
        return None
    video_id = track.get("videoId")
    if not video_id or not isinstance(video_id, str):
        return None

    length = track.get("length") or track.get("duration")
    seconds = track.get("duration_seconds")
    if seconds is None:
        seconds = _seconds(length)

    thumbs = _thumbnails(track.get("thumbnails"), track.get("thumbnail"))
    in_library = track.get("inLibrary")
    return {
        "videoId": video_id,
        "title": track.get("title") or "",
        "artists": _artists(track.get("artists")),
        "album": _album(track.get("album")),
        "thumbnails": thumbs,
        "duration": length if isinstance(length, str) else None,
        "durationSeconds": seconds,
        "inLibrary": bool(in_library) if in_library is not None else None,
        "source": source,
    }


# ---------------- radio + related ----------------

def fetch_radio(call, video_id: str, limit: int) -> tuple[list[dict], str | None]:
    """
    Real radio candidates for a seed song.

    Returns (normalized radio candidates, related-browse-id or None).
    Cached per seed for RADIO_CACHE_TTL — Start Radio and autoplay for the
    same track must not re-hit YouTube every time.
    """
    def produce():
        response = call(
            "get_watch_playlist", videoId=video_id, radio=True, limit=max(limit, 25)
        )
        if not isinstance(response, dict):
            return [], None
        tracks = response.get("tracks") or []
        candidates = []
        for t in tracks:
            cand = normalize_candidate(t, "radio")
            if cand:
                candidates.append(cand)
        related = response.get("related")
        return candidates, related if isinstance(related, str) and related else None

    return _cached(f"radio:{video_id}:{limit}", RADIO_CACHE_TTL, produce)


def fetch_related(call, browse_id: str, limit: int) -> list[dict]:
    """Song candidates from the watch panel's \"related\" shelves."""
    def produce():
        shelves = call("get_song_related", browseId=browse_id)
        candidates: list[dict] = []
        if not isinstance(shelves, list):
            return candidates
        for shelf in shelves:
            if not isinstance(shelf, dict):
                continue
            for item in shelf.get("contents") or []:
                cand = normalize_candidate(item, "related")
                if cand:
                    candidates.append(cand)
                    if len(candidates) >= limit:
                        return candidates
        return candidates

    return _cached(f"related:{browse_id}:{limit}", RELATED_CACHE_TTL, produce)


def get_radio_candidates(call, video_id: str, limit: int) -> list[dict]:
    """
    Radio first (provider order), then related songs as a fallback/extra —
    deduplicated, capped at 3x *limit* so the ranker has room to diversify.
    """
    radio, related_id = fetch_radio(call, video_id, limit)
    candidates = list(radio)
    if related_id:
        try:
            related = fetch_related(call, related_id, limit)
        except Exception as e:
            # Related enrichment is optional; radio alone still works.
            logger.warning("related fetch failed (%s)", type(e).__name__)
            related = []
        seen = {c["videoId"] for c in candidates}
        candidates.extend(c for c in related if c["videoId"] not in seen)
    return candidates[: max(limit * 3, limit)]


# ---------------- provider familiarity (cold start) ----------------

def provider_familiarity(call) -> dict:
    """
    {video_plays: {id: n}, artist_plays: {name: n}, liked: {id, ...}} built
    from the account's own YouTube Music history and liked songs, so a brand
    new install still ranks with real personal signal. Cached; every part is
    best-effort — a provider failure yields partial data, never an error.
    """
    def produce():
        out = {"video_plays": {}, "artist_plays": {}, "liked": set()}
        try:
            history = call("get_history") or []
        except Exception as e:
            logger.warning("get_history failed (%s)", type(e).__name__)
            history = []
        for item in history if isinstance(history, list) else []:
            if not isinstance(item, dict):
                continue
            vid = item.get("videoId")
            if not vid:
                continue
            out["video_plays"][vid] = out["video_plays"].get(vid, 0) + 1
            for a in _artists(item.get("artists")):
                name = a["name"]
                out["artist_plays"][name] = out["artist_plays"].get(name, 0) + 1

        try:
            liked = call("get_liked_songs", limit=300) or {}
        except Exception as e:
            logger.warning("get_liked_songs failed (%s)", type(e).__name__)
            liked = {}
        tracks = liked.get("tracks") if isinstance(liked, dict) else None
        for item in tracks or []:
            if isinstance(item, dict) and item.get("videoId"):
                out["liked"].add(item["videoId"])
        return out

    return _cached("familiarity", FAMILIARITY_CACHE_TTL, produce)
