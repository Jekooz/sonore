"""
Persistent local listening-history store.

Design constraints (from the task):
  * One write per finished/aborted track — never per playback-position tick.
    The frontend aggregates listened time locally and POSTs a single event
    when a track completes, is skipped, or stops.
  * Survives restarts, is written atomically (tmp + rename), and a corrupt or
    outdated file resets to empty instead of crashing the app.
  * Bounded: at most MAX_EVENTS events; the oldest are dropped first.
  * No secrets: events carry only music metadata and playback numbers.
    Session cookies / auth headers never reach this file.
  * No cloud: the file lives next to the app's other local data.

Storage layout (%LOCALAPPDATA%/ytmusic_client/listening_history.json):

    {
      "version": 1,
      "events": [ {videoId, title, artist, source, startedAt,
                   listenedSeconds, durationSeconds, outcome}, ... ],
      "ratings": { "<videoId>": "LIKE" | "DISLIKE" }   # explicit only
    }

`stats()` aggregates the raw events into the shapes the ranker consumes:
per-video play/completion/skip counts, per-artist counts, explicit ratings,
and the recent-video list. Aggregates are computed on read (a few thousand
short dicts — cheap) so the file itself never needs a migration.
"""

from __future__ import annotations

import json
import logging
import os
import threading
import time

logger = logging.getLogger("ytmusic-backend")

MAX_EVENTS = 1000
MAX_RECENT = 10          # distinct recent videos handed to the ranker
MAX_HISTORY_LIMIT = 100  # most rows GET /listening/history will return
VALID_OUTCOMES = ("completed", "skipped", "stopped")

# Bounded so a bad client cannot bloat the store.
MAX_TEXT = 200
MAX_SECONDS = 24 * 60 * 60


def _default_path() -> str:
    base = os.environ.get(
        "LOCALAPPDATA",
        os.path.join(os.path.expanduser("~"), "AppData", "Local"),
    )
    return os.path.join(base, "ytmusic_client", "listening_history.json")


class ListeningStore:
    """Thread-safe JSON-backed listening-event store."""

    def __init__(self, path: str | None = None):
        self._path = path or _default_path()
        self._lock = threading.Lock()
        self._data: dict | None = None  # lazy load

    # ---------------- persistence ----------------

    def _load(self) -> dict:
        if self._data is not None:
            return self._data
        try:
            if os.path.exists(self._path):
                with open(self._path, "r", encoding="utf-8") as f:
                    raw = json.load(f)
                if isinstance(raw, dict) and isinstance(raw.get("events"), list):
                    ratings = raw.get("ratings")
                    self._data = {
                        "version": 1,
                        "events": [e for e in raw["events"] if isinstance(e, dict)],
                        "ratings": ratings if isinstance(ratings, dict) else {},
                    }
                    return self._data
                raise ValueError("unexpected shape")
        except FileNotFoundError:
            pass
        except Exception as e:  # corrupt / outdated file
            # Never crash the app over history: start fresh (keep the bad file
            # aside once so it can be inspected, then continue).
            logger.warning("listening history unreadable (%s) — resetting.", type(e).__name__)
            try:
                os.replace(self._path, self._path + ".corrupt")
            except OSError:
                pass
        self._data = {"version": 1, "events": [], "ratings": {}}
        return self._data

    def _persist(self) -> None:
        try:
            directory = os.path.dirname(self._path)
            os.makedirs(directory, exist_ok=True)
            tmp = self._path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(self._data, f, separators=(",", ":"))
            os.replace(tmp, self._path)
        except OSError as e:
            # Disk trouble must never break playback or ranking.
            logger.warning("Could not persist listening history: %s", e)

    # ---------------- writes ----------------

    def record(self, event: dict) -> int:
        """
        Append one playback event and persist. Returns the stored event count.

        Values are validated and clamped here as well (the API layer validates
        before we ever see it, but the store must stand on its own).
        """
        video_id = str(event.get("videoId") or "").strip()
        if not video_id:
            raise ValueError("videoId is required")

        outcome = event.get("outcome")
        if outcome not in VALID_OUTCOMES:
            raise ValueError(f"outcome must be one of {VALID_OUTCOMES}")

        def _num(value, lo=0.0, hi=float(MAX_SECONDS)) -> float:
            try:
                return max(lo, min(hi, float(value)))
            except (TypeError, ValueError):
                return lo

        entry = {
            "videoId": video_id,
            "title": str(event.get("title") or "")[:MAX_TEXT],
            "artist": str(event.get("artist") or "")[:MAX_TEXT],
            "source": str(event.get("source") or "")[:32],
            "startedAt": _num(event.get("startedAt"), 0.0, 4e9) or time.time(),
            "listenedSeconds": _num(event.get("listenedSeconds")),
            "durationSeconds": _num(event.get("durationSeconds")),
            "outcome": outcome,
        }

        with self._lock:
            data = self._load()
            data["events"].append(entry)
            if len(data["events"]) > MAX_EVENTS:
                del data["events"][: len(data["events"]) - MAX_EVENTS]
            self._persist()
            return len(data["events"])

    def set_rating(self, video_id: str, rating: str) -> None:
        """Remember an EXPLICIT like/dislike (INDIFFERENT forgets it)."""
        if not video_id:
            return
        with self._lock:
            data = self._load()
            if rating == "INDIFFERENT":
                data["ratings"].pop(video_id, None)
            elif rating in ("LIKE", "DISLIKE"):
                data["ratings"][video_id] = rating
            else:
                raise ValueError("rating must be LIKE, DISLIKE or INDIFFERENT")
            self._persist()

    # ---------------- reads ----------------

    @property
    def event_count(self) -> int:
        with self._lock:
            return len(self._load()["events"])

    def clear(self) -> None:
        with self._lock:
            self._data = {"version": 1, "events": [], "ratings": {}}
            self._persist()

    def recent_plays(self, limit: int = 30) -> list[dict]:
        """
        The most recent distinct plays, newest first — what the app's History
        list shows.

        One row per video, carrying the metadata its newest event recorded
        (title, artist, outcome, when), so the client can list and replay them
        without a second provider call. Only this app's own events are here:
        nothing is fetched from or attributed to the service.
        """
        limit = max(1, min(int(limit), MAX_HISTORY_LIMIT))
        with self._lock:
            events = list(self._load()["events"])

        rows: dict[str, dict] = {}
        for ev in events:  # oldest first, so the newest event wins below
            vid = ev.get("videoId")
            if not vid:
                continue
            row = rows.get(vid)
            if row is None:
                rows[vid] = row = {
                    "videoId": vid,
                    "title": "",
                    "artist": "",
                    "plays": 0,
                    "lastAt": 0.0,
                    "lastOutcome": "",
                }
            row["plays"] += 1
            started = float(ev.get("startedAt") or 0)
            if started >= row["lastAt"]:
                row["lastAt"] = started
                row["lastOutcome"] = ev.get("outcome") or ""
                if ev.get("title"):
                    row["title"] = ev["title"]
                if ev.get("artist"):
                    row["artist"] = ev["artist"]

        ordered = sorted(rows.values(), key=lambda r: r["lastAt"], reverse=True)
        return ordered[:limit]

    def stats(self) -> dict:
        """
        Aggregated view for the ranker:

          videos:  videoId -> {plays, completed, early_skips, listened,
                               duration, last_at}
          artists: artist name -> {plays, completed}
          ratings: videoId -> LIKE / DISLIKE  (explicit only)
          recent:  videoIds of the last MAX_RECENT distinct plays,
                   newest first
        """
        with self._lock:
            data = self._load()
            events = list(data["events"])
            ratings = dict(data["ratings"])

        videos: dict[str, dict] = {}
        artists: dict[str, dict] = {}
        recent: list[str] = []

        # Oldest first so "last_at" and recency end up correct.
        for ev in events:
            vid = ev.get("videoId")
            if not vid:
                continue
            v = videos.setdefault(
                vid,
                {"plays": 0, "completed": 0, "early_skips": 0,
                 "listened": 0.0, "duration": 0.0, "last_at": 0.0},
            )
            v["plays"] += 1
            if ev.get("outcome") == "completed":
                v["completed"] += 1
            dur = float(ev.get("durationSeconds") or 0)
            listened = float(ev.get("listenedSeconds") or 0)
            # An early skip is a play that stopped well before the end
            # (completion ratio < 0.9 with a known duration). This is a weak
            # signal on purpose — the ranker caps its effect; only an
            # explicit dislike is treated as strong evidence.
            if dur >= 20 and listened < 0.9 * dur:
                v["early_skips"] += 1
            v["listened"] += listened
            v["duration"] += dur
            v["last_at"] = max(v["last_at"], float(ev.get("startedAt") or 0))

            artist = (ev.get("artist") or "").strip()
            if artist:
                a = artists.setdefault(artist, {"plays": 0, "completed": 0})
                a["plays"] += 1
                if ev.get("outcome") == "completed":
                    a["completed"] += 1

            if vid in recent:
                recent.remove(vid)
            recent.insert(0, vid)

        return {
            "videos": videos,
            "artists": artists,
            "ratings": ratings,
            "recent": recent[:MAX_RECENT],
        }


# Single shared instance used by the FastAPI app.
listening_store = ListeningStore()
