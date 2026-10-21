"""
The facade the API layer talks to: gather the three sources, blend them.

Two requests are answered here and nowhere else:

    recommend_home(...)   the "Recommended for you" row of the Home screen
    recommend_next(...)   what Autoplay adds when the queue runs low

Both follow the same shape: YouTube Music first, the local taste layer and
the outside signals refining it, and every optional layer degrading to
nothing rather than to an error.

Adding a fourth source later
----------------------------
The Gonic/FLAC library of the v2 plan slots in here without touching the
blender. A source is a callable that returns candidates in the shared shape
and never raises; the steps are:

  1. add the name and its weight to ``config.SOURCES`` / ``config.WEIGHTS``;
  2. write ``recommender/sources/<name>.py`` with a function that returns
     candidates (or nothing, when the library is not there);
  3. call it from ``recommend_home`` / ``recommend_next`` and put the result
     in the ``sources`` dict the blender is given.

The blender already merges an unknown source, and an item that carries no
video id is dropped rather than returned, so a local library of files that
cannot be played by this app cannot break the result.
"""

from __future__ import annotations

import logging
from typing import Callable

from .blender import blend
from .config import (
    DEFAULT_LIMIT,
    RECENT_BLOCK_COUNT,
    SOURCE_EXTERNAL,
    SOURCE_LOCAL,
    SOURCE_YOUTUBE,
    WEIGHTS,
)
from .settings import RecommenderSettings
from .sources import external as external_source
from .sources import local as local_source
from .sources import youtube as youtube_source
from .store import TasteStore

logger = logging.getLogger("ytmusic-backend")


def _filters(affinity: dict) -> tuple[list[str], list[str], list[str]]:
    """(recent, disliked, skipped) — the video ids the blender drops."""
    recent = list(affinity.get("recent") or [])[:RECENT_BLOCK_COUNT]
    disliked = list((affinity.get("disliked") or {}).keys())
    skipped = list((affinity.get("skipped") or {}).keys())
    return recent, disliked, skipped


def _local_affinity(store: TasteStore) -> dict:
    try:
        return store.affinity()
    except Exception as exc:  # noqa: BLE001 - no signal is not a failure
        logger.info("local affinity unavailable: %s", type(exc).__name__)
        return {}


def recommend_home(
    call: Callable[..., object],
    store: TasteStore,
    settings: RecommenderSettings,
    limit: int = DEFAULT_LIMIT,
) -> list[dict]:
    """
    The blended "Recommended for you" row.

    The provider's own row is the backbone; the local layer adds what this
    device likes and the outside services refine the result.
    """
    yt_items = youtube_source.home_candidates(call, limit=max(limit * 2, 20))

    affinity = _local_affinity(store) if settings.local_learning else {}
    local_items: list[dict] = []
    if settings.local_learning:
        local_items = local_source.local_candidates(call, store, limit=limit)

    external_items: list[dict] = []
    if settings.has_external:
        external_items = external_source.external_candidates(
            listenbrainz_token=settings.listenbrainz_token,
            lastfm_api_key=settings.lastfm_api_key,
            user=settings.listenbrainz_user,
            limit=limit,
        )

    recent, disliked, skipped = _filters(affinity)

    return blend(
        {
            SOURCE_YOUTUBE: yt_items,
            SOURCE_LOCAL: local_items,
            SOURCE_EXTERNAL: external_items,
        },
        limit=limit,
        weights=WEIGHTS,
        recent=recent,
        disliked=disliked,
        skipped=skipped,
    )


def recommend_next(
    call: Callable[..., object],
    store: TasteStore,
    settings: RecommenderSettings,
    seed: str,
    limit: int = DEFAULT_LIMIT,
    exclude: set[str] | None = None,
) -> list[dict]:
    """
    The blended candidates Autoplay adds after *seed*.

    The radio for the seed is the backbone — the provider knows what follows
    a track better than anything else here — and the other two layers refine
    it. The seed itself and the current queue never come back.
    """
    yt_items = youtube_source.seed_candidates(call, seed, limit=max(limit * 2, 25))

    affinity = _local_affinity(store) if settings.local_learning else {}
    local_items: list[dict] = []
    if settings.local_learning:
        local_items = local_source.local_candidates(call, store, limit=limit)

    seed_artist = str((affinity.get("track_artists") or {}).get(seed, ""))
    seed_title = str((affinity.get("titles") or {}).get(seed, ""))

    external_items: list[dict] = []
    if settings.has_external:
        external_items = external_source.external_candidates(
            listenbrainz_token=settings.listenbrainz_token,
            lastfm_api_key=settings.lastfm_api_key,
            user=settings.listenbrainz_user,
            seed_artist=seed_artist,
            seed_title=seed_title,
            limit=limit,
        )

    recent, disliked, skipped = _filters(affinity)
    blocked = set(exclude or ())
    blocked.add(seed)

    return blend(
        {
            SOURCE_YOUTUBE: yt_items,
            SOURCE_LOCAL: local_items,
            SOURCE_EXTERNAL: external_items,
        },
        limit=limit,
        weights=WEIGHTS,
        exclude=blocked,
        recent=recent,
        disliked=disliked,
        skipped=skipped,
    )
