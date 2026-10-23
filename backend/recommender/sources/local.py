"""
The local taste layer as a candidate source.

What the device knows comes from two places:

  * the provider's own liked songs — the user's explicit taste, and a list of
    real, playable tracks;
  * the tracks this device has played — which the local store remembers with
    their video ids, titles and artists.

Both are scored by the local model (the store's recency-decayed affinity), so
an item the user played last week counts for more than one from last month,
and a track that was skipped in its first seconds counts for less than
nothing.

The layer never invents a track: every candidate it returns carries a video
id the device or the provider actually knows.
"""

from __future__ import annotations

import logging
from typing import Callable

from services import recommend

from ..cache import cached
from ..config import LOCAL_CACHE_TTL, SOURCE_LOCAL
from ..store import TasteStore

logger = logging.getLogger("ytmusic-backend")

#: How many liked songs are asked for.
LIKED_LIMIT = 300

#: How many of the device's own recent plays are offered as candidates.
RECENT_CANDIDATE_LIMIT = 20


def _squash(score: float) -> float:
    """
    Fit a raw affinity into 0..1 without a hard ceiling.

    A score of 1.0 becomes 0.5, 3.0 becomes 0.75, 9.0 becomes 0.9: the more
    evidence there is, the closer to 1 it gets, but it never runs away.
    """
    if score <= 0.0:
        return 0.0
    return score / (score + 1.0)


def _candidate_from_store(
    video_id: str,
    affinity: dict,
    artists: list[str],
) -> dict | None:
    """One of the device's own plays as a candidate."""
    titles = affinity.get("titles") or {}
    track_artists = affinity.get("track_artists") or {}
    title = titles.get(video_id, "")
    if not title:
        return None
    score = float((affinity.get("tracks") or {}).get(video_id, 0.0))
    if score <= 0.0:
        return None
    names = artists or ([track_artists[video_id]] if track_artists.get(video_id) else [])
    return {
        "videoId": video_id,
        "title": title,
        "artists": [{"name": name, "id": None} for name in names],
        "album": None,
        "thumbnails": [],
        "duration": None,
        "durationSeconds": None,
        "inLibrary": None,
        "source": SOURCE_LOCAL,
        "affinity": _squash(score),
    }


def local_candidates(
    call: Callable[..., object],
    store: TasteStore,
    limit: int = 20,
) -> list[dict]:
    """
    The candidates the device's own taste vouches for.

    call:   the provider client, used only for the liked-songs list
    store:  the local taste store, which holds the affinity model
    """
    if limit <= 0:
        return []

    def produce() -> list[dict]:
        try:
            affinity = store.affinity()
        except Exception as exc:  # noqa: BLE001 - no signal is not a failure
            logger.warning("local affinity unavailable (%s)", type(exc).__name__)
            return []

        candidates: list[dict] = []
        seen: set[str] = set()

        # The user's own likes: real tracks, explicitly vouched for.
        try:
            liked = call("get_liked_songs", limit=LIKED_LIMIT) or {}
        except Exception as exc:  # noqa: BLE001 - the provider may refuse
            logger.warning("liked songs unavailable (%s)", type(exc).__name__)
            liked = {}

        tracks = liked.get("tracks") if isinstance(liked, dict) else None
        for item in tracks or []:
            candidate = recommend.normalize_candidate(item, "liked")
            if not candidate:
                continue
            video_id = candidate["videoId"]
            if video_id in seen:
                continue
            score = float((affinity.get("tracks") or {}).get(video_id, 0.0))
            if score <= 0.0:
                # The local layer only vouches for what it has seen; the
                # provider's likes are still the provider's business.
                continue
            seen.add(video_id)
            candidate = dict(candidate)
            candidate["source"] = SOURCE_LOCAL
            candidate["affinity"] = _squash(score)
            candidates.append(candidate)

        # The tracks this device played, which the store remembers by id.
        recent = list(affinity.get("recent") or [])[:RECENT_CANDIDATE_LIMIT]
        for video_id in recent:
            if video_id in seen:
                continue
            candidate = _candidate_from_store(video_id, affinity, [])
            if not candidate:
                continue
            seen.add(video_id)
            candidates.append(candidate)

        return candidates[:limit]

    return cached("local:candidates", LOCAL_CACHE_TTL, produce)
