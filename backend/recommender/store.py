"""
The local taste layer: what this device has learned by playing, skipping and
liking.

Storage
-------
One SQLite file inside the app's own data directory
(``%LOCALAPPDATA%\\Sonore\\taste.db`` on Windows). Nothing is written outside
it, and the tables hold only music metadata and playback numbers — no
cookies, no session, no signed URL, ever.

    plays  (video_id, title, artist, ts, completed)
    skips  (video_id, title, artist, ts, played_fraction)
    likes  (video_id, title, artist, ts)

The model
---------
Affinity is a recency-decayed sum of what happened:

  * a play is worth [PLAY_AFFINITY], and finishing the track adds
    [COMPLETION_BONUS] on top;
  * a like is worth [LIKE_AFFINITY] — the strongest positive signal;
  * a skip in the first [SKIP_NEGATIVE_FRACTION] of the track *takes away*
    [SKIP_PENALTY]: the listener heard a moment and moved on;
  * a later skip takes away only [MILD_SKIP_PENALTY].

Every contribution is multiplied by ``0.5 ** (age_days / halflife)``, so a
play from yesterday counts for twice what the same play did a fortnight ago.

The score of a track is mostly its *artist*'s score: one favourite song
should not make an artist, and [TRACK_SHARE] keeps the track's own history
to a minority of the total.
"""

from __future__ import annotations

import os
import sqlite3
import threading
import time

from services.ytmusic_client import app_data_dir

from .config import (
    COMPLETION_BONUS,
    LIKE_AFFINITY,
    MAX_PLAYS_PER_TRACK,
    MAX_ROWS,
    MILD_SKIP_PENALTY,
    PLAY_AFFINITY,
    RECENCY_HALFLIFE_DAYS,
    SKIP_NEGATIVE_FRACTION,
    SKIP_PENALTY,
    TASTE_DB_FILENAME,
    TRACK_SHARE,
)

_SCHEMA = """
CREATE TABLE IF NOT EXISTS plays (
    video_id  TEXT NOT NULL,
    title     TEXT NOT NULL DEFAULT '',
    artist    TEXT NOT NULL DEFAULT '',
    ts        REAL NOT NULL,
    completed INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS skips (
    video_id       TEXT NOT NULL,
    title          TEXT NOT NULL DEFAULT '',
    artist         TEXT NOT NULL DEFAULT '',
    ts             REAL NOT NULL,
    played_fraction REAL NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS likes (
    video_id TEXT NOT NULL,
    title    TEXT NOT NULL DEFAULT '',
    artist   TEXT NOT NULL DEFAULT '',
    ts       REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS plays_video ON plays (video_id);
CREATE INDEX IF NOT EXISTS skips_video ON skips (video_id);
CREATE INDEX IF NOT EXISTS likes_video ON likes (video_id);
"""


def data_dir() -> str:
    """
    The app's own data directory.

    ``SONORE_DATA_DIR`` overrides it, which is how a test — or a second copy
    of the app — keeps its data to itself. The default is the same place the
    install token lives, so everything the app owns is in one folder.
    """
    override = os.environ.get("SONORE_DATA_DIR")
    if override:
        return override
    return app_data_dir()


def default_db_path() -> str:
    """Where the taste database lives by default."""
    return os.path.join(data_dir(), TASTE_DB_FILENAME)


def _decay(ts: float, now: float) -> float:
    """How much a signal from *ts* still counts, given the half-life."""
    age_days = max(0.0, (now - float(ts)) / 86400.0)
    return 0.5 ** (age_days / RECENCY_HALFLIFE_DAYS)


class TasteStore:
    """
    The SQLite-backed local taste layer.

    Every method is safe to call from any thread, and every method is
    best-effort: a broken database must never take the app down, so failures
    are swallowed and the layer simply reports no signal.
    """

    def __init__(self, path: str | None = None):
        self._explicit = path
        self._lock = threading.RLock()
        self._ready = False

    @property
    def path(self) -> str:
        """
        Where the database lives.

        Resolved on use rather than at construction, so a store created
        before the data directory is redirected still ends up in the right
        place.
        """
        return self._explicit or default_db_path()

    # ---------------- plumbing ----------------

    def _connect(self) -> sqlite3.Connection:
        directory = os.path.dirname(self.path)
        if directory:
            os.makedirs(directory, exist_ok=True)
        conn = sqlite3.connect(self.path, timeout=5.0)
        conn.row_factory = sqlite3.Row
        return conn

    def _ensure_schema(self) -> None:
        if self._ready:
            return
        with self._lock:
            if self._ready:
                return
            try:
                with self._connect() as conn:
                    conn.executescript(_SCHEMA)
                self._ready = True
            except sqlite3.Error:
                # A store that cannot be opened is a store with no signal, not
                # a crash: the recommender runs without it.
                self._ready = True

    def _trim(self, conn: sqlite3.Connection, table: str) -> None:
        try:
            conn.execute(
                f"DELETE FROM {table} WHERE rowid NOT IN ("
                f"SELECT rowid FROM {table} ORDER BY ts DESC LIMIT ?)",
                (MAX_ROWS,),
            )
        except sqlite3.Error:
            pass

    # ---------------- writes ----------------

    def record_play(
        self,
        video_id: str,
        title: str = "",
        artist: str = "",
        ts: float | None = None,
        completed: bool = True,
    ) -> bool:
        """Remember that a track was played. Returns True when it was stored."""
        if not video_id:
            return False
        self._ensure_schema()
        try:
            with self._lock, self._connect() as conn:
                conn.execute(
                    "INSERT INTO plays (video_id, title, artist, ts, completed)"
                    " VALUES (?, ?, ?, ?, ?)",
                    (
                        str(video_id),
                        str(title or "")[:200],
                        str(artist or "")[:200],
                        float(ts if ts is not None else time.time()),
                        1 if completed else 0,
                    ),
                )
                self._trim(conn, "plays")
        except sqlite3.Error:
            return False
        return True

    def record_skip(
        self,
        video_id: str,
        title: str = "",
        artist: str = "",
        ts: float | None = None,
        played_fraction: float = 0.0,
    ) -> bool:
        """Remember that a track was skipped, and how far it got."""
        if not video_id:
            return False
        self._ensure_schema()
        try:
            fraction = max(0.0, min(1.0, float(played_fraction or 0.0)))
            with self._lock, self._connect() as conn:
                conn.execute(
                    "INSERT INTO skips (video_id, title, artist, ts, played_fraction)"
                    " VALUES (?, ?, ?, ?, ?)",
                    (
                        str(video_id),
                        str(title or "")[:200],
                        str(artist or "")[:200],
                        float(ts if ts is not None else time.time()),
                        fraction,
                    ),
                )
                self._trim(conn, "skips")
        except sqlite3.Error:
            return False
        return True

    def record_like(
        self,
        video_id: str,
        title: str = "",
        artist: str = "",
        ts: float | None = None,
    ) -> bool:
        """Remember an explicit like. The strongest positive signal there is."""
        if not video_id:
            return False
        self._ensure_schema()
        try:
            with self._lock, self._connect() as conn:
                conn.execute(
                    "INSERT INTO likes (video_id, title, artist, ts)"
                    " VALUES (?, ?, ?, ?)",
                    (
                        str(video_id),
                        str(title or "")[:200],
                        str(artist or "")[:200],
                        float(ts if ts is not None else time.time()),
                    ),
                )
                self._trim(conn, "likes")
        except sqlite3.Error:
            return False
        return True

    def clear(self) -> None:
        """Forget everything this device learned."""
        self._ensure_schema()
        try:
            with self._lock, self._connect() as conn:
                conn.execute("DELETE FROM plays")
                conn.execute("DELETE FROM skips")
                conn.execute("DELETE FROM likes")
        except sqlite3.Error:
            pass

    # ---------------- reads ----------------

    def affinity(self, now: float | None = None) -> dict:
        """
        The derived taste model.

            artists    {artist name: score}
            tracks     {video id: score}
            disliked   {video id: score}   (negative: skipped early)
            skipped    {video id: score}   (any skip, negative)
            recent     [video id, ...]     (newest first)
            titles     {video id: title}
            track_artists {video id: artist}
        """
        self._ensure_schema()
        moment = float(now if now is not None else time.time())
        artists: dict[str, float] = {}
        tracks: dict[str, float] = {}
        disliked: dict[str, float] = {}
        skipped: dict[str, float] = {}
        recent: list[str] = []
        titles: dict[str, str] = {}
        track_artists: dict[str, str] = {}

        def _bump(bucket: dict[str, float], key: str, amount: float) -> None:
            if not key:
                return
            bucket[key] = bucket.get(key, 0.0) + amount

        try:
            with self._lock, self._connect() as conn:
                plays = conn.execute(
                    "SELECT video_id, title, artist, ts, completed FROM plays"
                    " ORDER BY ts DESC"
                ).fetchall()
                skips = conn.execute(
                    "SELECT video_id, title, artist, ts, played_fraction FROM skips"
                    " ORDER BY ts DESC"
                ).fetchall()
                likes = conn.execute(
                    "SELECT video_id, title, artist, ts FROM likes"
                    " ORDER BY ts DESC"
                ).fetchall()
        except sqlite3.Error:
            return {
                "artists": {},
                "tracks": {},
                "disliked": {},
                "skipped": {},
                "recent": [],
                "titles": {},
                "track_artists": {},
            }

        seen_plays = 0
        for row in plays:
            video_id = (row["video_id"] or "").strip()
            if not video_id:
                continue
            seen_plays += 1
            if seen_plays > MAX_PLAYS_PER_TRACK * 20:
                break
            weight = _decay(row["ts"], moment)
            value = PLAY_AFFINITY * weight
            if row["completed"]:
                value += COMPLETION_BONUS * weight
            artist = (row["artist"] or "").strip()
            title = (row["title"] or "").strip()
            if title:
                titles.setdefault(video_id, title)
            if artist:
                track_artists.setdefault(video_id, artist)
            _bump(tracks, video_id, value)
            _bump(artists, artist, value)
            if video_id not in recent:
                recent.append(video_id)

        for row in skips:
            video_id = (row["video_id"] or "").strip()
            if not video_id:
                continue
            weight = _decay(row["ts"], moment)
            fraction = float(row["played_fraction"] or 0.0)
            if fraction < SKIP_NEGATIVE_FRACTION:
                penalty = SKIP_PENALTY * weight
                _bump(disliked, video_id, penalty)
                _bump(skipped, video_id, penalty)
                _bump(tracks, video_id, -penalty)
                artist = (row["artist"] or "").strip()
                if artist:
                    _bump(artists, artist, -penalty)
            else:
                penalty = MILD_SKIP_PENALTY * weight
                _bump(skipped, video_id, penalty)
                _bump(tracks, video_id, -penalty)
            if (row["title"] or "").strip():
                titles.setdefault(video_id, row["title"].strip())
            if (row["artist"] or "").strip():
                track_artists.setdefault(video_id, row["artist"].strip())

        for row in likes:
            video_id = (row["video_id"] or "").strip()
            if not video_id:
                continue
            weight = _decay(row["ts"], moment)
            _bump(tracks, video_id, LIKE_AFFINITY * weight)
            artist = (row["artist"] or "").strip()
            if artist:
                _bump(artists, artist, LIKE_AFFINITY * weight)
            if (row["title"] or "").strip():
                titles.setdefault(video_id, row["title"].strip())
            if artist:
                track_artists.setdefault(video_id, artist)
            if video_id not in recent:
                recent.append(video_id)

        # The artist's score carries most of a track's score: one favourite
        # song should not make an artist.
        for video_id, track_score in list(tracks.items()):
            artist = track_artists.get(video_id, "")
            artist_score = artists.get(artist, 0.0)
            tracks[video_id] = track_score * TRACK_SHARE + artist_score * (
                1.0 - TRACK_SHARE
            )

        return {
            "artists": artists,
            "tracks": tracks,
            "disliked": disliked,
            "skipped": skipped,
            "recent": recent,
            "titles": titles,
            "track_artists": track_artists,
        }

    def counts(self) -> dict:
        """How much the store holds, for the Settings page."""
        self._ensure_schema()
        counts = {"plays": 0, "skips": 0, "likes": 0}
        try:
            with self._lock, self._connect() as conn:
                for table in counts:
                    row = conn.execute(f"SELECT COUNT(*) AS n FROM {table}").fetchone()
                    counts[table] = int(row["n"] or 0)
        except sqlite3.Error:
            pass
        return counts
