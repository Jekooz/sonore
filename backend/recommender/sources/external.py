"""
Outside signals: ListenBrainz and Last.fm.

Both are optional. Neither is required for the recommender to work, and
neither is ever allowed to fail a request:

  * nothing is configured — no token, no key — the source is skipped;
  * the service answers with an error, times out, or answers with something
    unexpected — the source is skipped and the rest of the request carries
    on as if it had never been asked.

The tokens and keys come from the settings store (see ``recommender/settings``)
and are never hardcoded here, logged, or committed.

What the outside services can and cannot do
--------------------------------------------
ListenBrainz knows artists and songs; Last.fm knows similar artists and
similar tracks. Neither knows a YouTube Music video id, so what they produce
are *hints*: artists and songs that match what the provider already offered.
The blender turns a matching hint into a boost, and a hint that matches
nothing is dropped.
"""

from __future__ import annotations

import json
import logging
import urllib.error
import urllib.parse
import urllib.request
from typing import Callable

from ..cache import cached
from ..config import (
    EXTERNAL_CACHE_TTL,
    EXTERNAL_MAX_BYTES,
    EXTERNAL_SEED_ARTIST,
    EXTERNAL_SIMILAR_LIMIT,
    EXTERNAL_TIMEOUT,
    LASTFM_SIMILAR_ARTIST_URL,
    LASTFM_SIMILAR_TRACK_URL,
    LISTENBRAINZ_LISTENS_URL,
    LISTENBRAINZ_USER,
    SOURCE_EXTERNAL,
)

logger = logging.getLogger("ytmusic-backend")

#: How much an outside service is trusted, per kind of hint.
SIMILAR_ARTIST_AFFINITY = 0.60
SIMILAR_TRACK_AFFINITY = 0.85
LISTEN_AFFINITY = 0.70

#: The signature of the injectable fetch: url, headers → body text.
Fetcher = Callable[[str, dict], str]


def _default_fetch(url: str, headers: dict) -> str:
    """GET *url*, read at most the configured cap, never raise."""
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=EXTERNAL_TIMEOUT) as response:
        data = response.read(EXTERNAL_MAX_BYTES)
    if isinstance(data, bytes):
        return data.decode("utf-8", errors="replace")
    return str(data)


def _json(text: str) -> object:
    try:
        return json.loads(text)
    except (TypeError, ValueError):
        return None


def _hint(artist: str, title: str, affinity: float) -> dict | None:
    """One outside hint, in the candidate shape."""
    artist = (artist or "").strip()
    title = (title or "").strip()
    if not artist and not title:
        return None
    return {
        "videoId": None,
        "title": title,
        "artists": [{"name": artist, "id": None}] if artist else [],
        "album": None,
        "thumbnails": [],
        "duration": None,
        "durationSeconds": None,
        "inLibrary": None,
        "source": SOURCE_EXTERNAL,
        "affinity": affinity,
    }


def _listenbrainz_hints(
    fetch: Fetcher,
    token: str,
    user: str,
    limit: int,
) -> list[dict]:
    """The artists and songs this account has listened to."""
    url = LISTENBRAINZ_LISTENS_URL.format(user=urllib.parse.quote(user))
    headers = {"Authorization": f"Token {token}", "Accept": "application/json"}
    body = _json(fetch(url, headers))
    if not isinstance(body, list):
        return []

    hints: list[dict] = []
    for entry in body:
        if not isinstance(entry, dict):
            continue
        metadata = entry.get("track_metadata")
        if not isinstance(metadata, dict):
            continue
        artist = str(metadata.get("artist_name") or "")
        title = str(metadata.get("track_name") or "")
        hint = _hint(artist, title, LISTEN_AFFINITY)
        if hint:
            hints.append(hint)
        if len(hints) >= limit:
            break
    return hints


def _lastfm_artist_hints(
    fetch: Fetcher,
    api_key: str,
    artist: str,
    limit: int,
) -> list[dict]:
    """The artists Last.fm considers similar to *artist*."""
    url = LASTFM_SIMILAR_ARTIST_URL.format(
        limit=limit,
        artist=urllib.parse.quote(artist or ""),
    ) + f"&api_key={urllib.parse.quote(api_key)}"
    body = _json(fetch(url, {"Accept": "application/json"}))
    if not isinstance(body, dict):
        return []
    similar = body.get("similarartists")
    entries = similar.get("artist") if isinstance(similar, dict) else None
    hints: list[dict] = []
    for entry in entries or []:
        if not isinstance(entry, dict):
            continue
        hint = _hint(str(entry.get("name") or ""), "", SIMILAR_ARTIST_AFFINITY)
        if hint:
            hints.append(hint)
        if len(hints) >= limit:
            break
    return hints


def _lastfm_track_hints(
    fetch: Fetcher,
    api_key: str,
    artist: str,
    track: str,
    limit: int,
) -> list[dict]:
    """The songs Last.fm considers similar to *artist* / *track*."""
    if not artist or not track:
        return []
    url = LASTFM_SIMILAR_TRACK_URL.format(
        limit=limit,
        artist=urllib.parse.quote(artist),
        track=urllib.parse.quote(track),
    ) + f"&api_key={urllib.parse.quote(api_key)}"
    body = _json(fetch(url, {"Accept": "application/json"}))
    if not isinstance(body, dict):
        return []
    similar = body.get("similartracks")
    entries = similar.get("track") if isinstance(similar, dict) else None
    hints: list[dict] = []
    for entry in entries or []:
        if not isinstance(entry, dict):
            continue
        credit = entry.get("artist")
        name = credit.get("name") if isinstance(credit, dict) else str(credit or "")
        hint = _hint(str(name or ""), str(entry.get("name") or ""), SIMILAR_TRACK_AFFINITY)
        if hint:
            hints.append(hint)
        if len(hints) >= limit:
            break
    return hints


def external_candidates(
    *,
    listenbrainz_token: str = "",
    lastfm_api_key: str = "",
    seed_artist: str = "",
    seed_title: str = "",
    user: str = LISTENBRAINZ_USER,
    limit: int = 20,
    fetch: Fetcher | None = None,
) -> list[dict]:
    """
    The outside hints, or nothing at all.

    Every failure — a missing token, a timeout, an error status, a body that
    is not the shape expected — yields no hints and no exception. The caller
    blends what it has.
    """
    if not listenbrainz_token and not lastfm_api_key:
        # Not configured: the source does not exist for this install.
        return []

    def produce() -> list[dict]:
        getter = fetch or _default_fetch
        hints: list[dict] = []

        def _safe(url: str, headers: dict) -> str:
            try:
                return getter(url, headers)
            except (urllib.error.URLError, OSError, ValueError) as exc:
                logger.info("external source unavailable: %s", type(exc).__name__)
                return ""

        if listenbrainz_token:
            try:
                hints.extend(
                    _listenbrainz_hints(
                        _safe, listenbrainz_token, user, limit
                    )
                )
            except Exception as exc:  # noqa: BLE001 - never fatal
                logger.info("listenbrainz skipped: %s", type(exc).__name__)

        if lastfm_api_key:
            artist = seed_artist or EXTERNAL_SEED_ARTIST
            try:
                hints.extend(
                    _lastfm_artist_hints(_safe, lastfm_api_key, artist, limit)
                )
            except Exception as exc:  # noqa: BLE001 - never fatal
                logger.info("last.fm artists skipped: %s", type(exc).__name__)
            try:
                hints.extend(
                    _lastfm_track_hints(
                        _safe, lastfm_api_key, artist, seed_title, limit
                    )
                )
            except Exception as exc:  # noqa: BLE001 - never fatal
                logger.info("last.fm tracks skipped: %s", type(exc).__name__)

        return hints[:limit]

    return cached(
        "external:hints:%s:%s:%s:%s"
        % (bool(listenbrainz_token), bool(lastfm_api_key), seed_artist, seed_title),
        EXTERNAL_CACHE_TTL,
        produce,
    )
