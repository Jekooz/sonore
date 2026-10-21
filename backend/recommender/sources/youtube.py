"""
The YouTube Music source — the primary one.

Everything here goes through the provider client the app already injects
(``ytmusic_service.call``), and it reuses the candidate normalisation and the
radio retrieval that ``services/recommend.py`` already has, so nothing is
fetched twice and the shape of a candidate stays the one the rest of the app
already understands.

Two entry points:

  * ``seed_candidates`` — the radio for a seed track, which is what Autoplay
    asks for. It calls ``services.recommend.get_radio_candidates``, which is
    radio plus the related shelves, already cached.
  * ``home_candidates`` — the "Recommended for you" row of the home feed, for
    the Home screen.

Both are cached for a short while: the feed changes slowly, and a Home screen
that asks the provider on every rebuild is a Home screen that stutters.
"""

from __future__ import annotations

import logging
from typing import Callable

from services import recommend

from ..cache import cached
from ..config import SOURCE_YOUTUBE, YT_CACHE_TTL

logger = logging.getLogger("ytmusic-backend")

#: The home row that carries the provider's own recommendations. The title
#: changes with the provider's locale, so the match is loose and the first
#: row that carries playable songs is the fallback.
RECOMMENDED_ROW_HINTS = ("recommended for you", "recommended", "for you")

#: A provider row is worth less the further down it is, the same way the
#: existing ranker treats provider order.
PROVIDER_DECAY = 0.07


def _affinity(index: int) -> float:
    """How much the provider's own order is worth for the item at *index*."""
    return 1.0 / (1.0 + PROVIDER_DECAY * index)


def _with_affinity(candidates: list[dict], source: str) -> list[dict]:
    """Stamp the provider's order onto each candidate as its affinity."""
    out: list[dict] = []
    for index, candidate in enumerate(candidates):
        item = dict(candidate)
        item["source"] = source
        item["affinity"] = _affinity(index)
        out.append(item)
    return out


def seed_candidates(
    call: Callable[..., object],
    video_id: str,
    limit: int = 25,
) -> list[dict]:
    """
    The provider's radio for a seed track.

    Reuses ``services.recommend.get_radio_candidates`` — radio plus the
    related shelves — so the autoplay path keeps the behaviour it has today
    and the caching it already has.

    A provider failure is *not* swallowed here: the provider is the backbone
    of the answer, and a request that cannot reach it must say so rather than
    answer with an empty list.
    """
    if not video_id:
        return []

    def produce() -> list[dict]:
        candidates = recommend.get_radio_candidates(call, video_id, limit)
        return _with_affinity(candidates, SOURCE_YOUTUBE)

    return cached(f"yt:seed:{video_id}:{limit}", YT_CACHE_TTL, produce)


def home_candidates(
    call: Callable[..., object],
    limit: int = 20,
) -> list[dict]:
    """
    The provider's own "Recommended for you" songs, from the home feed.

    The feed is a list of rows; the recommendation row is the one that names
    itself, and when no row does the first row that actually carries songs is
    used instead.

    A provider failure propagates, exactly as in [seed_candidates]: the
    provider is the backbone, and a failure is reported rather than hidden.
    """

    def produce() -> list[dict]:
        rows = call("get_home", limit=6)
        if not isinstance(rows, list):
            return []

        chosen: list[dict] = []
        fallback: list[dict] = []

        for row in rows:
            if not isinstance(row, dict):
                continue
            title = str(row.get("title") or "").strip().lower()
            contents = row.get("contents")
            if not isinstance(contents, list):
                continue

            songs: list[dict] = []
            for item in contents:
                candidate = recommend.normalize_candidate(item, "home")
                if candidate:
                    songs.append(candidate)
            if not songs:
                continue

            if not fallback:
                fallback = songs
            if any(hint in title for hint in RECOMMENDED_ROW_HINTS):
                chosen = songs
                break

        return _with_affinity(chosen or fallback, SOURCE_YOUTUBE)

    return cached("yt:home", YT_CACHE_TTL, produce)
