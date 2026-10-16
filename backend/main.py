"""
YouTube Music sidecar backend.

Run directly (python main.py) — listens on 127.0.0.1:8000 and writes its port to
%TEMP%/ytmusic_sidecar_port.txt so the frontend can discover it.

Endpoints:
  GET  /health                  liveness probe
  GET  /auth/status             signed in or not
  POST /auth/cookies            complete sign-in with cookies captured by the app
  POST /auth/signout            forget the stored session
  GET  /account                 account name / handle / photo
  GET  /home                    personalized home rows
  GET  /library/playlists       your playlists
  GET  /library/artists         your subscribed artists
  GET  /library/albums          your saved albums
  GET  /library/songs           your saved songs
  GET  /library/subscriptions   channel subscriptions
  POST /library/subscriptions   follow / unfollow one artist
  GET  /library/liked           liked songs
  GET  /search?q=...            search songs / albums / artists / playlists
  GET  /radio?videoId=...       real YT Music radio candidates for a seed song
  GET  /recommendations?...     ranked autoplay candidates (radio + related,
                                re-ranked with the local listening history)
  POST /listening/events        one aggregated playback event per track
  POST /ratings                 like / dislike / remove rating (rate_song)
  GET  /lyrics/{video_id}       real lyrics, timestamped when YouTube supplies them
"""

import http.client
import json
import logging
import os
import re
import secrets
import shutil
import socket
import subprocess
import tempfile
import threading
import time

import uvicorn
from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.responses import JSONResponse

from pydantic import BaseModel, Field
from typing import Literal
from ytmusicapi import YTMusic

from services.browser_auth import (
    WAIT_TIMEOUT_SECONDS,
    BrowserAuthSession,
    detect_default_browser,
)
from services import ranking, recommend
from services.listening import listening_store
from services.ytmusic_client import (
    REQUIRED_COOKIES,
    AuthError,
    StorageError,
    sanitize_account,
    ytmusic_service,
)

app = FastAPI()
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("ytmusic-backend")

# The published port file. Defaults to %TEMP%/ytmusic_sidecar_port.txt, the
# production discovery contract the app (and the old WinUI sidecar launcher)
# read. YTM_PORT_FILE overrides the path so an isolated instance -- a test, or a
# second copy on the same machine -- can publish without touching the shared
# file and without disturbing a live app.
PORT_FILE = os.environ.get("YTM_PORT_FILE") or os.path.join(
    tempfile.gettempdir(), "ytmusic_sidecar_port.txt"
)

# The port this process is actually listening on. Set in __main__ before
# uvicorn.run so the extension can be told where to call back; the request URL
# is only a fallback for a backend started some other way.
_BOUND_PORT = 0

# Where the companion extension lives. This is the ONLY folder a pairing file
# can work from: an extension page may fetch resources only from its own
# installation (Chrome docs, "Cross-origin network requests"), so a config file
# anywhere else on disk is unreadable by the extension by design.
_EXTENSION_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "browser-extension"
)
PAIRING_FILE = os.path.join(_EXTENSION_DIR, "sidecar.json")


@app.get("/health")
def health():
    return JSONResponse(content={"status": "ok"})


# ---------------- auth ----------------


@app.get("/auth/status")
def auth_status():
    try:
        signed_in = ytmusic_service.is_signed_in()
        return JSONResponse(content={"logged_in": signed_in, "error": None})
    except Exception:
        # Audit finding 6: str/repr of an upstream error can carry request
        # detail (a real leak was captured live during this audit). The log is
        # the place for the full text; the API side stays generic.
        logger.exception("auth/status failed")
        return JSONResponse(content={"logged_in": False, "error": None})


def _log_cookie_count(cookies: dict, source: str, missing: list[str] | None = None) -> None:
    """Log COUNTS only, never cookie names and never values."""
    line = f"{source}: received {len(cookies)} cookies"
    if missing:
        line += f", {len(missing)} of {len(REQUIRED_COOKIES)} required cookie names missing"
    logger.info(line)


def _validate_and_store(cookies: dict, source: str) -> dict:
    """
    Shared completion path for every cookie source (WebView2 historically;
    browser/extension hand-off now). Gate on required session cookies, confirm
    the candidate against YouTube, and only then store it encrypted. A bad
    hand-off therefore fails loudly here without disturbing the session that is
    already stored. Anonymous cookies like YSC/VISITOR_INFO1_LIVE alone do NOT
    count as signed in.
    """
    missing = [n for n in REQUIRED_COOKIES if not cookies.get(n)]
    _log_cookie_count(cookies, source, missing)
    if missing:
        # 422 (not 401): the request delivered data, just not a signed-in set.
        if any(cookies.get(n) for n in REQUIRED_COOKIES):
            quantifier = "some"
        else:
            quantifier = "none"
        raise HTTPException(
            status_code=422,
            detail=(
                f"Sign-in incomplete: {quantifier} of the required session cookies "
                f"are present ({len(missing)} of {len(REQUIRED_COOKIES)} missing). "
                "Sign in to music.youtube.com in your browser, then try again."
            ),
        )

    # Validate the candidate BEFORE touching the credential store (M2).
    #
    # The previous order stored first and cleared the session when YouTube then
    # rejected it, so a single bad hand-off -- wrong account, stale cookies,
    # half a jar -- destroyed a working session. Verification now runs against a
    # throwaway client built from these cookies, leaving whatever is already
    # stored completely untouched.
    try:
        account = ytmusic_service.verify_candidate(cookies)
    except AuthError as e:
        logger.error("Candidate session from %s is incomplete: %s", source, e)
        # detail is OUR wording only: AuthError texts never embed upstream
        # exception text (audit finding 6).
        raise HTTPException(status_code=422, detail=str(e))
    except Exception as e:
        # Log the full text server-side; the client gets a generic line. The
        # previous ": {e}" echoed a complete upstream JSON document into the
        # HTTP response (captured live in the audit run).
        logger.error(
            "Candidate session from %s was rejected by YouTube (%s): %s",
            source, type(e).__name__, e)
        raise HTTPException(
            status_code=401,
            detail="Sign-in could not be verified with YouTube Music. Try again, then sign in again.",
        )

    # Only now persist. StorageError subclasses AuthError, so it goes first.
    try:
        result = ytmusic_service.store_session(cookies)
    except StorageError as e:
        logger.error("Credential storage failed: %s", e)
        raise HTTPException(status_code=500, detail="Could not store the session locally.")
    except Exception as e:
        logger.exception("Storing session failed")
        raise HTTPException(status_code=500, detail="Could not store the session locally.")

    result["account"] = account
    return result


@app.post("/auth/cookies")
async def auth_cookies(payload: dict, request: Request):
    """
    Complete sign-in. Body: {"cookies": {"SID": "...", "__Secure-3PAPISID": "...", ...}}

    Security fix (audit finding 1): this route installs a full Google session,
    so it now runs under the same gate as /auth/extension — a sign-in attempt
    must actually be waiting, and the request must carry its single-use pairing
    token in X-Ytm-Token. A bare POST to the loopback port can no longer
    install or replace a session. No shipped UI calls this endpoint (both
    frontends use /auth/browser/start + /auth/extension), so gating it breaks
    nothing that works; check auth headers first if you are wiring a new
    programmatic caller.
    """
    cookies = payload.get("cookies")
    if not isinstance(cookies, dict) or not cookies:
        raise HTTPException(status_code=400, detail="Body must contain a 'cookies' object.")
    if not _sign_in_pending():
        logger.warning("Rejected /auth/cookies: no sign-in in progress.")
        raise HTTPException(
            status_code=409,
            detail="No sign-in is in progress. Start sign-in from the app first.",
        )
    rejection = _consume_pairing_token(request.headers.get("X-Ytm-Token"))
    if rejection is not None:
        logger.warning("Rejected /auth/cookies: %s", rejection)
        raise HTTPException(status_code=401, detail=rejection)
    return JSONResponse(content=_validate_and_store(cookies, "auth/cookies"))


@app.post("/auth/signout")
def auth_signout():
    ytmusic_service.clear_session()
    return JSONResponse(content={"signed_out": True})


# ---------------- browser-based sign-in (replaces the WebView2 window) ----------------

# The active BrowserAuthSession for this process, if a sign-in is in flight.
_browser_session: BrowserAuthSession | None = None
_browser_session_lock = threading.Lock()

# Placed here by /auth/extension when the hand-off arrives. The session's poll
# thread picks it up (cookie_source below), closing the loop without polling
# playlists or disk.
_extension_cookies: dict | None = None
_extension_cookies_event = threading.Event()


def _extension_cookie_source() -> dict | None:
    """Strategy-B source: the extension POSTs its youtube.com jar here."""
    global _extension_cookies
    if _extension_cookies_event.wait(0.1):
        _extension_cookies_event.clear()
        jar = _extension_cookies
        # Drop our copy: the session is already stored by the time this runs, so
        # there is no reason to keep raw session cookies in memory afterwards.
        _extension_cookies = None
        return jar
    return None


def _clear_browser_session() -> None:
    global _browser_session
    with _browser_session_lock:
        if _browser_session is not None:
            _browser_session.cancel()
        _browser_session = None


# ---------------- extension pairing token ----------------

# Sign-in hardening (M2). The hand-off used to be accepted from any local caller
# at any time, and the X-Ytm-Token header was documented but never read. Now every
# attempt issues one cryptographically random token, publishes {port, token} where
# only the extension can read it, and demands that exact token back before anything
# is stored. The token is single-use (consumed before the cookie jar is touched),
# expires with the attempt, and is rotated by every new attempt -- so an
# unsolicited request, a stale token and a replay are all rejected. Token values
# are never logged.
_pairing_token: str | None = None
_pairing_issued_at = 0.0


def _current_port(request: Request) -> int:
    """The port the extension must call back on."""
    return _BOUND_PORT or request.url.port or 0


def _write_pairing_file(port: int, token: str) -> bool:
    """Publish {port, token} for the extension to read.

    Best-effort: if the folder is missing or unwritable the attempt simply
    cannot pair, which the UI already reports, so this must never raise.
    """
    try:
        os.makedirs(_EXTENSION_DIR, exist_ok=True)
        tmp_path = PAIRING_FILE + ".tmp"
        with open(tmp_path, "w", encoding="utf-8") as f:
            json.dump({"port": port, "token": token}, f)
        os.replace(tmp_path, PAIRING_FILE)
        return True
    except OSError as e:
        logger.warning("Could not publish the extension pairing file: %s", e)
        return False


def _clear_pairing() -> None:
    """Invalidate the pairing token and remove its file. Idempotent."""
    global _pairing_token, _pairing_issued_at
    _pairing_token = None
    _pairing_issued_at = 0.0
    try:
        if os.path.exists(PAIRING_FILE):
            os.remove(PAIRING_FILE)
    except OSError as e:
        logger.warning("Could not remove the extension pairing file: %s", e)


# Serialises issue/consume of the pairing token. Without it two concurrent
# hand-off requests could both pass compare_digest before either nulls the
# token (audit finding 7): the check-and-clear must be one atomic step.
_pairing_lock = threading.Lock()


def _issue_pairing(port: int) -> None:
    """Rotate the pairing token for a new attempt.

    Rotation is what retires the previous attempt's token: only the newest
    hand-off can complete, even if an older popup is still open somewhere.
    """
    global _pairing_token, _pairing_issued_at
    with _pairing_lock:
        _pairing_token = secrets.token_urlsafe(32)
        _pairing_issued_at = time.monotonic()
    if _write_pairing_file(port, _pairing_token):
        logger.info(
            "Sign-in pairing token issued for port %s (valid %d s).",
            port, int(WAIT_TIMEOUT_SECONDS),
        )


def _consume_pairing_token(provided: str | None) -> str | None:
    """Validate the handshake token, or return why the request must be rejected.

    A wrong token is NOT consumed, so a retry with the right one still works
    (guessing is hopeless against 256 bits of entropy). A correct token IS
    consumed here, before the caller stores anything, which is what makes a
    replay impossible.
    """
    global _pairing_token, _pairing_issued_at
    if not provided:
        return "Missing pairing token."
    # The check-and-clear runs under the lock so exactly one of N concurrent
    # requests holding a valid token can consume it (audit finding 7).
    with _pairing_lock:
        if _pairing_token is None or not secrets.compare_digest(provided, _pairing_token):
            return "Invalid pairing token."
        if time.monotonic() - _pairing_issued_at > WAIT_TIMEOUT_SECONDS:
            return "Pairing token expired."
        _pairing_token = None
        _pairing_issued_at = 0.0
    return None


def _sign_in_pending() -> bool:
    """True while an attempt is actually waiting for a hand-off.

    A timed-out, failed, cancelled or completed attempt still leaves an object
    in _browser_session, so the state -- not merely its existence -- decides
    whether a hand-off may be accepted.
    """
    session = _browser_session
    return session is not None and session.status().get("state") == "waiting"


@app.get("/auth/browser/info")
def auth_browser_info():
    """Friendly name of the default HTTPS browser, for the UI's prompt text."""
    return JSONResponse(content={"browser": detect_default_browser()})


@app.get("/auth/extension/folder")
def auth_extension_folder():
    """The one folder the companion extension can be installed from.

    A browser only lets an extension read files inside its own installation, so
    the pairing file this service writes is readable from here and nowhere else.
    That makes this folder a step the user has to take - load it unpacked - which
    is why the sign-in screen names it rather than leaving the hand-off to time
    out with no explanation.
    """
    return JSONResponse(content={"folder": _EXTENSION_DIR})


@app.post("/auth/browser/start")
def auth_browser_start(request: Request):
    """
    Start a sign-in: detect the default browser, open music.youtube.com in it,
    and poll (2 s interval, 3 min timeout) for the extension hand-off. The UI
    follows along via /auth/browser/status.

    Also rotates the handshake token and publishes {port, token} into the
    extension folder -- the only location the extension is able to read it from.
    """
    global _browser_session, _extension_cookies

    _clear_browser_session()
    # Security fix (audit finding 9): without this global declaration this
    # assignment created a LOCAL, module-invisible variable, so a residual jar
    # from a cancelled or timed-out attempt stayed in module memory after every
    # new attempt cleared the event only.
    _extension_cookies = None
    _extension_cookies_event.clear()

    session = BrowserAuthSession(cookie_source=_extension_cookie_source)
    with _browser_session_lock:
        _browser_session = session

    # The session must exist before the token is issued: a hand-off is only
    # accepted while an attempt is actually waiting.
    _issue_pairing(_current_port(request))

    session.start()
    return JSONResponse(content=session.status())


@app.get("/auth/browser/status")
def auth_browser_status():
    if _browser_session is None:
        return JSONResponse(
            content={"state": "idle", "browser": detect_default_browser(), "error": None}
        )

    status = _browser_session.status()
    if status.get("state") != "waiting":
        # Terminal state: the pairing file must not outlive the attempt it was
        # issued for. Idempotent, and it is also the only thing that cleans up
        # after a timeout.
        _clear_pairing()
    return JSONResponse(content=status)


@app.post("/auth/browser/cancel")
def auth_browser_cancel():
    _clear_browser_session()
    _clear_pairing()
    return JSONResponse(content={"state": "cancelled"})


@app.post("/auth/extension")
def auth_extension(payload: dict, request: Request):
    """
    Extension hand-off: the MV3 companion extension reads youtube.com cookies
    (chrome.cookies includes HttpOnly) and POSTs them here. Same validation +
    storage as /auth/cookies, then the waiting browser session is marked done.

    Auth: X-Ytm-Token must be the single-use pairing token this backend wrote to
    browser-extension/sidecar.json when sign-in started. That rejects an
    unsolicited caller, a token left over from an earlier attempt, and a replay
    of one already accepted. 409 when no attempt is waiting; 401 otherwise.
    Token and cookie VALUES are never logged.
    """
    global _extension_cookies

    # Order matters (audit finding 8): is anything waiting, is the BODY well
    # formed, is the caller authorised, then storage. Malformed-body 400s must
    # not burn the single-use attempt — the caller may simply have fluffed a
    # request and still hold the only token they get for it.
    if not _sign_in_pending():
        logger.warning("Rejected extension hand-off: no sign-in in progress.")
        raise HTTPException(
            status_code=409,
            detail="No sign-in is in progress. Start sign-in from the app first.",
        )

    cookies = payload.get("cookies")
    if not isinstance(cookies, dict) or not cookies:
        raise HTTPException(status_code=400, detail="Body must contain a 'cookies' object.")

    rejection = _consume_pairing_token(request.headers.get("X-Ytm-Token"))
    if rejection is not None:
        logger.warning("Rejected extension hand-off: %s", rejection)
        raise HTTPException(status_code=401, detail=rejection)

<<<<<<< HEAD
    # A present-but-EMPTY jar is not a malformed body. The extension always
    # sends {"cookies": {...}}, and it is empty exactly when the browser it is
    # loaded in has no YouTube Music session -- the common real case, because
    # the app opens whatever the default browser is. Measured live against the
    # installed build: this used to answer the popup with "Body must contain a
    # 'cookies' object." and, since the 400 was raised outside the handler
    # below, the app then waited out its full three minutes with nothing on
    # screen. Routing it through the shared validation says what is actually
    # wrong (no session cookies present) and fails the attempt, so the UI
    # reports it at once instead of appearing to hang.
    cookies = payload.get("cookies")
    if not isinstance(cookies, dict):
        raise HTTPException(status_code=400, detail="Body must contain a 'cookies' object.")

=======
>>>>>>> 6a014a8 (WIP: light palette + pairing gate
)
    try:
        result = _validate_and_store(cookies, "auth/extension")
    except HTTPException as e:
        if _browser_session is not None:
            _browser_session.fail(e.detail)
        raise

    _extension_cookies = cookies
    _extension_cookies_event.set()

    return JSONResponse(content=result)


# ---------------- account + data ----------------


def _data(method: str, **kwargs):
    """Shared wrapper for authenticated data calls -> 401 on auth problems."""
    try:
        return ytmusic_service.call(method, **kwargs)
    except AuthError as e:
        # AuthError texts are OUR wording (audit finding 6): safe to surface.
        raise HTTPException(status_code=401, detail=str(e))
    except Exception:
        logger.exception("%s failed", method)
        raise HTTPException(
            status_code=502,
            detail="YouTube Music request failed. Try again shortly.",
        )


@app.get("/account")
def account():
    # Sanitized here as well as in verify_candidate: the service's `accountName`
    # has answered with one of its own chrome labels ("Home") on a real session,
    # and Settings must never show that as the signed-in account.
    return JSONResponse(content=sanitize_account(_data("get_account_info")))


@app.get("/home")
def home():
    rows = _data("get_home", limit=6)
    # Keep only rows that actually have content to render.
    return JSONResponse(content=[r for r in rows if r.get("contents")])


@app.get("/library/playlists")
def library_playlists():
    playlists = _data("get_library_playlists", limit=50) or []
    normalized = []
    for p in playlists:
        item = dict(p)
        author_val = p.get("author") or p.get("authors") or p.get("owner")
        item["author"] = _credit_names(author_val) if author_val else ""
        normalized.append(item)
    return JSONResponse(content=normalized)


@app.get("/library/artists")
def library_artists():
    return JSONResponse(content=_data("get_library_artists", limit=50))


@app.get("/library/albums")
def library_albums():
    return JSONResponse(content=_data("get_library_albums", limit=50))


@app.get("/library/songs")
def library_songs():
    return JSONResponse(content=_data("get_library_songs", limit=100))


@app.get("/library/subscriptions")
def library_subscriptions():
    return JSONResponse(content=_data("get_library_subscriptions", limit=50))


@app.get("/library/liked")
def library_liked():
    liked = _data("get_liked_songs", limit=300)
    return JSONResponse(content=liked.get("tracks", []))


# Album / playlist contents.
#
# The Home, Library and Search cards carry only an id — a browseId for albums
# (MPREb_…) or a playlistId for playlists. Without these two endpoints there was
# no way to turn a collection card into playable tracks, so clicking an album or
# playlist did nothing at all and only single songs could play.
def _normalize_album(track: dict) -> dict:
    """Force the album field to the object shape the client DTO expects.

    get_album() returns "album" as a plain string ("AUJLA SZN 1"), while
    get_playlist()/get_liked_songs() return {"name": ..., "id": ...}. The
    frontend Track DTO models the object shape, so a raw string made
    deserialization throw (JsonException -> AlbumRef) and the album never
    played. Normalizing here keeps one shape for every track list.
    """
    album = track.get("album")
    if isinstance(album, str):
        return {**track, "album": {"name": album, "id": None}}
    return track


def _credit_names(value) -> str:
    """One credit line from ytmusicapi's inconsistent credit fields.

    get_album() puts the performers in a list of {name,id}; get_playlist()
    puts a single {name,id} in author (or owner). Normalizing keeps the
    collection header from rendering "System.Collections..." or blank.
    """
    if isinstance(value, list):
        return ", ".join(
            n["name"] for n in value if isinstance(n, dict) and n.get("name")
        )
    if isinstance(value, dict):
        return value.get("name") or ""
    if isinstance(value, str):
        return value
    return ""


def _collection(kind: str, title, subtitle, thumbnails, tracks) -> dict:
    """The one payload shape every collection page reads.

    Album / playlist / artist all return {kind, title, subtitle, thumbnails,
    trackCount, tracks} so the collection page can render its header and its
    tracklist from a single fetch, and playback can reuse the same response
    instead of hitting the backend twice.
    """
    return {
        "kind": kind,
        "title": title or "Unknown",
        "subtitle": subtitle or "",
        "thumbnails": thumbnails,
        "trackCount": len(tracks),
        "tracks": tracks,
    }


# NOTE: _data(method, **kwargs) forwards kwargs to the ytmusicapi method, so the
# argument names must be its own (browseId / playlistId / channelId) — passing
# positionally raises TypeError, which surfaces as a 500 rather than a 502.
@app.get("/album/{browse_id}")
def album_detail(browse_id: str):
    """An album as a collection: real metadata + real track list (get_album)."""
    album = _data("get_album", browseId=browse_id) or {}
    tracks = [_normalize_album(t) for t in (album.get("tracks") or [])]
    subtitle = _credit_names(album.get("artists")) or _credit_names(album.get("artist"))
    year = album.get("year")
    if year and subtitle:
        subtitle = f"{subtitle} \u00b7 {year}"
    elif year:
        subtitle = str(year)
    return JSONResponse(
        content=_collection(
            "album", album.get("title"), subtitle, album.get("thumbnails"), tracks
        )
    )


@app.get("/playlist/{playlist_id}")
def playlist_detail(playlist_id: str):
    """A playlist as a collection: real metadata + real track list (get_playlist)."""
    playlist = _data("get_playlist", playlistId=playlist_id) or {}
    tracks = playlist.get("tracks") or []
    subtitle = (
        _credit_names(playlist.get("author"))
        or _credit_names(playlist.get("owner"))
        or _credit_names(playlist.get("privacy"))
    )
    return JSONResponse(
        content=_collection(
            "playlist",
            playlist.get("title"),
            subtitle,
            playlist.get("thumbnails"),
            tracks,
        )
    )


@app.get("/artist/{channel_id}")
def artist_detail(channel_id: str):
    """An artist as a collection: their real top songs, playable as a tracklist.

    get_artist() nests the songs under {"songs": {"results": [...]}}; each row
    already carries a videoId, so the artist page can play any track the user
    picks. Albums/singles live under their own keys and are not tracks, so they
    are not flattened in here.
    """
    artist = _data("get_artist", channelId=channel_id) or {}
    songs = (artist.get("songs") or {}).get("results") or []
    tracks = [_normalize_album(t) for t in songs]
    return JSONResponse(
        content=_collection(
            "artist",
            artist.get("name"),
            artist.get("subscribers"),
            artist.get("thumbnails"),
            tracks,
        )
    )


# Search categories the frontend filter chips can ask for, mapped to the
# real ytmusicapi search() filters. Chips drive server-side filtering, which
# the user sees as Tabs on music.youtube.com (Songs / Videos / Albums / …).
SEARCH_FILTERS = {
    "songs": "songs",
    "videos": "videos",
    "albums": "albums",
    "artists": "artists",
    "playlists": "playlists",
}


@app.get("/search")
def search(
    q: str = Query(..., min_length=1),
    filter: str | None = Query(default=None),
):
    """
    Search YouTube Music.

    filter: optional category (songs|videos|albums|artists|playlists) — when
    set, the query goes through ytmusicapi's real search filter, exactly like
    picking a tab on the YT Music web app. Without it a general search
    returns the mixed result list (each item still carries its real
    resultType, which the frontend renders as a small type badge).
    """
    kwargs = {"query": q, "limit": 20}
    if filter:
        if filter not in SEARCH_FILTERS:
            raise HTTPException(
                status_code=400,
                detail=f"Unknown search filter '{filter}'. "
                + "Allowed: " + ", ".join(SEARCH_FILTERS),
            )
        kwargs["filter"] = SEARCH_FILTERS[filter]
    results = _data("search", **kwargs)
    return JSONResponse(content=results)


# ---------------- recommendations / ratings / listening history ----------------

# Video ids are the same 6-20 char URL-safe alphabet YouTube uses; every id
# that reaches yt-dlp or ytmusicapi passes this gate first (also used by
# /stream).
_VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{6,20}$")

# Artist channel ids are longer than a video id (a real one is "UC" plus 22
# characters, and library rows use the "MPLAUC" browse form). The pattern is
# deliberately permissive on the prefix and bounded in length: a malformed id is
# rejected here, everything else is left to the provider to accept or refuse.
_ARTIST_ID_RE = re.compile(r"^[A-Za-z0-9_-]{6,64}$")

# Sensible limits on candidate counts and stored-history operations.
MAX_CANDIDATES = 50
MAX_EXCLUDE_IDS = 200


class ListeningEventIn(BaseModel):
    """One aggregated playback event, sent once when a track ends/aborts."""

    videoId: str = Field(pattern=_VIDEO_ID_RE.pattern)
    title: str | None = Field(default=None, max_length=300)
    artist: str | None = Field(default=None, max_length=300)
    source: str | None = Field(default=None, max_length=32)
    startedAt: float | None = Field(default=None, ge=0, le=4e9)
    listenedSeconds: float = Field(default=0, ge=0, le=86400)
    durationSeconds: float = Field(default=0, ge=0, le=86400)
    outcome: Literal["completed", "skipped", "stopped"]


class RatingIn(BaseModel):
    """Explicit song rating — like, dislike, or remove the rating."""

    videoId: str = Field(pattern=_VIDEO_ID_RE.pattern)
    rating: Literal["LIKE", "DISLIKE", "INDIFFERENT"]


class SubscriptionIn(BaseModel):
    """Follow or unfollow one artist channel."""

    artistId: str = Field(pattern=_ARTIST_ID_RE.pattern)
    subscribed: bool


def _validate_video_id(video_id: str) -> None:
    if not _VIDEO_ID_RE.fullmatch(video_id):
        raise HTTPException(status_code=400, detail="Invalid video id.")


def _parse_exclude(exclude: str | None) -> set[str]:
    """Comma-separated video ids → validated set (bounded)."""
    if not exclude:
        return set()
    ids = [e.strip() for e in exclude.split(",") if e.strip()]
    if len(ids) > MAX_EXCLUDE_IDS:
        raise HTTPException(
            status_code=400,
            detail=f"Too many exclude ids (max {MAX_EXCLUDE_IDS}).",
        )
    for vid in ids:
        _validate_video_id(vid)
    return set(ids)


def _ranked_candidates(seed: str, limit: int, exclude: set[str]) -> dict:
    """
    Shared path for /radio and /recommendations: real provider candidates
    (radio + related), re-ranked with the local listening store and the
    account's own YT Music history/likes. Provider failures surface as the
    usual 401/502 through this helper — never as an empty-looking success.
    """
    try:
        candidates = recommend.get_radio_candidates(
            ytmusic_service.call, seed, max(limit * 2, 25)
        )
    except AuthError as e:
        # AuthError texts are OUR wording (audit finding 6): safe to surface.
        raise HTTPException(status_code=401, detail=str(e))
    except Exception:
        logger.exception("radio candidate fetch failed")
        raise HTTPException(
            status_code=502,
            detail="YouTube Music request failed. Try again shortly.",
        )

    # The seed itself, the whole current queue and recent repeats must not
    # come back as “new” recommendations.
    blocked = set(exclude)
    blocked.add(seed)

    # Local stats and provider familiarity are best-effort enrichment:
    # ranking still works (cold) when either is unavailable, so neither may
    # fail the request.
    try:
        stats = listening_store.stats()
    except Exception:
        logger.exception("listening stats unavailable; ranking cold")
        stats = None
    try:
        familiarity = recommend.provider_familiarity(ytmusic_service.call)
    except Exception:
        logger.exception("provider familiarity unavailable; ranking cold")
        familiarity = None

    tracks = ranking.rank(
        candidates,
        stats=stats,
        familiarity=familiarity,
        limit=limit,
        exclude=blocked,
    )
    return {"seed": seed, "tracks": tracks, "count": len(tracks)}


@app.get("/radio")
def radio(
    videoId: str = Query(..., description="Seed video id"),
    limit: int = Query(30, ge=1, le=MAX_CANDIDATES),
):
    """Start Radio: genuine YT Music radio (+ related) for one seed song."""
    _validate_video_id(videoId)
    payload = _ranked_candidates(videoId, limit, exclude=set())
    payload["source"] = "radio"
    return JSONResponse(content=payload)


@app.get("/recommendations")
def recommendations(
    seed: str = Query(..., description="Current video id"),
    limit: int = Query(12, ge=1, le=MAX_CANDIDATES),
    exclude: str | None = Query(
        default=None,
        description="Comma-separated videoIds already in the queue (bounded)",
    ),
):
    """Autoplay: ranked candidates to append while the queue runs low."""
    _validate_video_id(seed)
    blocked = _parse_exclude(exclude)
    payload = _ranked_candidates(seed, limit, exclude=blocked)
    payload["source"] = "recommendations"
    return JSONResponse(content=payload)


@app.post("/listening/events")
def listening_events(event: ListeningEventIn):
    """
    Store one aggregated playback event (not a position tick). The store
    validates again, clamps numbers and caps growth; no secrets are kept.
    """
    try:
        total = listening_store.record(event.model_dump())
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    return JSONResponse(content={"recorded": True, "events": total})


@app.get("/listening/history")
def listening_history(limit: int = Query(30, ge=1, le=100)):
    """
    The most recent distinct tracks this app played, newest first.

    This is the app's own record (the same store the ranker reads), not a
    claim about the account's YouTube Music history, and it holds no session
    data — only video ids, titles, artists and playback numbers.
    """
    entries = listening_store.recent_plays(limit)
    return JSONResponse(content={"entries": entries, "count": len(entries)})


@app.post("/ratings")
def ratings(payload: RatingIn):
    """
    Genuine like / dislike / unlike via ytmusicapi's rate_song. The explicit
    rating is also remembered locally so the ranker can weigh it — distinct
    from adding/removing the song in the library (a different provider op
    this endpoint deliberately does not perform).
    """
    _data("rate_song", videoId=payload.videoId, rating=payload.rating)
    try:
        listening_store.set_rating(payload.videoId, payload.rating)
    except Exception:
        # The provider rating is the source of truth; a local-memory failure
        # must not turn a successful rating into an error response.
        logger.exception("Could not remember rating locally")
    return JSONResponse(
        content={"videoId": payload.videoId, "rating": payload.rating, "ok": True}
    )


# The subscription toggle lives here rather than beside the other /library/
# reads on purpose: its request model (defined with the others, above) has to
# exist before FastAPI builds the route, and the model block sits after the
# library reads.
@app.post("/library/subscriptions")
def set_subscription(payload: SubscriptionIn):
    """Follow or unfollow one artist channel.

    A genuine account change — the same operation the YouTube Music UI performs.
    ytmusicapi's ``subscribe_artist`` takes one channel; unsubscribing goes
    through ``unsubscribe_artists`` (a list), which is the only remove method the
    library exposes. The plural subscribe form is deprecated upstream, so it is
    deliberately not used.
    """
    if payload.subscribed:
        _data("subscribe_artist", channelId=payload.artistId)
    else:
        _data("unsubscribe_artists", channelIds=[payload.artistId])
    return JSONResponse(
        content={"artistId": payload.artistId, "subscribed": payload.subscribed}
    )


# ---------------- playback ----------------

# googlevideo URLs are signed and expire in about 6 hours; keep them a little
# less than that so a listening session never starts playing a dead link.
#
# Audit finding 10: the cache had no size cap and entries were never evicted,
# only read with a freshness check — one long-lived process would grow the map
# without bound. The entries are now evicted on insert (expired first, then the
# soonest-to-expire) and a hard cap bounds the map size.
_STREAM_CACHE: dict[str, tuple[str, float]] = {}
_STREAM_TTL_SECONDS = 4 * 60 * 60
_STREAM_CACHE_MAX = 240

# Audit finding 10: /stream called _resolve_stream directly, so nothing
# limited how many yt-dlp subprocesses could run concurrently (a burst of
# distinct tracks, a prefetch racing a manual play). This gate bounds the
# live subprocesses; callers beyond it queue briefly and then get 503.
_RESOLVE_GATE = threading.BoundedSemaphore(2)
_RESOLVE_GATE_WAIT_SECONDS = 20

# yt-dlp ships as a WinGet exe on this machine; resolve it at import time so a
# missing binary produces one clear 503 instead of an unhandled crash.
_YT_DLP = shutil.which("yt-dlp") or "yt-dlp"

# itag 140 (m4a/AAC) plays through Windows Media Foundation. Prefer it, but
# fall back to whatever audio YouTube serves rather than failing outright.
_AUDIO_FORMAT = "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]/bestaudio"


def _warm_stream_cache(video_id: str) -> None:
    """Resolve a stream URL in the background so a later /stream request hits the
    cache instead of paying the yt-dlp subprocess cost (~3 s cold, measured).
    Errors are swallowed: prefetch may fail for an unplayable video, the solve
    path itself reports that properly when the track is actually requested."""
    try:
        _resolve_stream(video_id)
        logger.info("prefetch: warmed stream cache for %s", video_id)
    except HTTPException:
        # Unplayable id (dead/expired link): leave the cache clean.
        pass
    except Exception:
        logger.exception("prefetch failed for %s", video_id)


# At most one warm-up runs at a time: a burst of /prefetch calls must not
# queue dozens of yt-dlp subprocesses behind each other.
_prefetch_lock = threading.Lock()


@app.get("/prefetch/{video_id}")
def prefetch(video_id: str):
    """Warm the stream-URL cache for a video id (fire-and-forget, bounded)."""
    if not _VIDEO_ID_RE.fullmatch(video_id):
        raise HTTPException(status_code=400, detail="Invalid video id.")
    # 202 Accepted: the work started (or already ran); the response does not
    # wait for it. If the URL is already cached this returns immediately.
    if video_id in _STREAM_CACHE and _STREAM_CACHE[video_id][1] > time.time():
        return JSONResponse(status_code=200, content={"videoId": video_id, "warmed": "cached"})
    if not _prefetch_lock.acquire(blocking=False):
        return JSONResponse(status_code=202, content={"videoId": video_id, "warmed": "skipped-busy"})

    def worker():
        try:
            _warm_stream_cache(video_id)
        finally:
            # The warm-up finishes while holding the gate: concurrent prefetch
            # requests are skipped (never queued), so yt-dlp subprocesses cannot
            # pile up.
            _prefetch_lock.release()

    threading.Thread(target=worker, daemon=True).start()
    return JSONResponse(status_code=202, content={"videoId": video_id, "warmed": "started"})


def _resolve_stream(video_id: str) -> str:
    """Resolve a playable audio URL for a video id using yt-dlp.

    Invoked as a subprocess (no shell) with the id passed as a single argv
    element, so the id is never interpreted by a shell.
    """
    now = time.time()
    cached = _STREAM_CACHE.get(video_id)
    if cached and cached[1] > now:
        return cached[0]

    # Bound the concurrent yt-dlp subprocesses (audit finding 10): callers
    # beyond the two live gates queue briefly, then get a clean 503 instead of
    # piling dozens of subprocesses up.
    if not _RESOLVE_GATE.acquire(timeout=_RESOLVE_GATE_WAIT_SECONDS):
        logger.warning("yt-dlp still busy after %ss for %s", _RESOLVE_GATE_WAIT_SECONDS, video_id)
        raise HTTPException(
            status_code=503,
            detail="Stream resolution is busy. Retry in a moment.",
        )
    try:
        proc = subprocess.run(
            [
                _YT_DLP,
                "-f",
                _AUDIO_FORMAT,
                "--get-url",
                "--no-warnings",
                "--no-playlist",
                f"https://www.youtube.com/watch?v={video_id}",
            ],
            capture_output=True,
            text=True,
            timeout=45,
        )
    except FileNotFoundError:
        raise HTTPException(
            status_code=503,
            detail="yt-dlp was not found on PATH. Install it and restart the app.",
        )
    except subprocess.TimeoutExpired:
        raise HTTPException(
            status_code=504,
            detail="Timed out resolving a stream URL for this track.",
        )
    finally:
        _RESOLVE_GATE.release()

    lines = [ln.strip() for ln in (proc.stdout or "").splitlines() if ln.strip()]
    if proc.returncode != 0 or not lines:
        err = [ln for ln in (proc.stderr or "").splitlines() if ln.strip()]
        reason = err[-1] if err else f"yt-dlp exited {proc.returncode}"
        # Server log keeps the full stderr (audit finding 6): yt-dlp's output
        # has already been seen echoing signer URLs and account context, so the
        # HTTP detail stays generic.
        logger.error("yt-dlp failed for %s: %s", video_id, reason)
        raise HTTPException(
            status_code=502,
            detail="Could not resolve a stream for this track. It may be unavailable.",
        )

    url = lines[-1]
    _store_stream_url(video_id, url, now + _STREAM_TTL_SECONDS)
    return url


def _store_stream_url(video_id: str, url: str, expires_at: float) -> None:
    """Insert into the stream cache with eviction (audit finding 10).

    Expired entries and, if the map is still full, the soonest-to-expire
    entries are dropped first. Dict mutation happens on single atomic ops per
    key, which is enough here: entries are independently recomputable.
    """
    if len(_STREAM_CACHE) >= _STREAM_CACHE_MAX:
        evict = len(_STREAM_CACHE) - _STREAM_CACHE_MAX + 1
        for vid, _ in sorted(_STREAM_CACHE.items(), key=lambda kv: kv[1][1])[:evict]:
            _STREAM_CACHE.pop(vid, None)
    _STREAM_CACHE[video_id] = (url, expires_at)


@app.get("/stream/{video_id}")
def stream(video_id: str):
    """Return a short-lived audio URL for the player to fetch directly."""
    if not _VIDEO_ID_RE.fullmatch(video_id):
        raise HTTPException(status_code=400, detail="Invalid video id.")
    return JSONResponse(content={"videoId": video_id, "url": _resolve_stream(video_id)})


# ---------------- lyrics ----------------
#
# Two real upstream calls: the watch playlist yields this track's lyrics browse
# id, which ytmusicapi's get_lyrics resolves -- with timestamps whenever YouTube
# supplies them. Nothing is ever invented when it does not: an untimed response
# is returned as plain text and the client renders static lyrics.
_LYRICS_CACHE: dict[str, tuple[float, dict]] = {}
_LYRICS_CACHE_MAX = 64
_LYRICS_TTL_SECONDS = 60 * 60
_lyrics_lock = threading.Lock()


def _lyrics_cached(video_id: str) -> dict | None:
    with _lyrics_lock:
        entry = _LYRICS_CACHE.get(video_id)
        if entry is None:
            return None
        expires, payload = entry
        if expires < time.time():
            _LYRICS_CACHE.pop(video_id, None)
            return None
        return payload


def _lyrics_store(video_id: str, payload: dict) -> None:
    with _lyrics_lock:
        if len(_LYRICS_CACHE) >= _LYRICS_CACHE_MAX:
            _LYRICS_CACHE.clear()
        _LYRICS_CACHE[video_id] = (time.time() + _LYRICS_TTL_SECONDS, payload)


# get_lyrics(timestamps=True) is served on YouTube's mobile endpoints and is
# rejected (HTTP 400) when the logged-in account context rides along with it.
# Lyrics are public data, so the timed lookup goes through a throwaway
# anonymous client; the stored session is never read, written or cleared, and
# as_mobile() mutates the client it is called on, so fetches are serialised.
_lyrics_fetch_lock = threading.Lock()


def _fetch_lyrics(video_id: str) -> dict:
    """Resolve real lyrics for a video id. Returns {"available": False} when
    YouTube Music has none, which is an answer, not an error."""
    watch = _data("get_watch_playlist", videoId=video_id, limit=1)
    browse_id = watch.get("lyrics") if isinstance(watch, dict) else None
    if not browse_id or not isinstance(browse_id, str):
        return {"available": False}

    payload = None
    with _lyrics_fetch_lock:
        try:
            payload = YTMusic().get_lyrics(browse_id, timestamps=True)
        except Exception as e:
            # Not a failure worth surfacing: fall through to the untimed lookup.
            logger.info("Timed lyrics unavailable for %s (%s)", video_id, type(e).__name__)

    synced = isinstance(payload, dict) and payload.get("hasTimestamps") is True
    if not synced:
        # Static lyrics. Never invent timings when the provider supplies none.
        payload = _data("get_lyrics", browseId=browse_id, timestamps=False)

    if not payload or not isinstance(payload, dict):
        return {"available": False}

    raw = payload.get("lyrics")
    source = payload.get("source") if isinstance(payload.get("source"), str) else None

    if synced:
        lines = []
        for line in raw:
            text = (getattr(line, "text", None) or "").strip()
            if not text:
                continue
            lines.append(
                {
                    "text": text,
                    "startMs": int(getattr(line, "start_time", 0) or 0),
                    "endMs": int(getattr(line, "end_time", 0) or 0),
                }
            )
        if not lines:
            return {"available": False}
        return {"available": True, "synced": True, "lines": lines, "source": source}

    if isinstance(raw, str) and raw.strip():
        lines = [
            {"text": text}
            for text in (part.strip() for part in raw.splitlines())
            if text
        ]
        if not lines:
            return {"available": False}
        return {"available": True, "synced": False, "lines": lines, "source": source}

    return {"available": False}


@app.get("/lyrics/{video_id}")
def lyrics(video_id: str):
    """Real lyrics for the current track.

    200  {available: true, synced, lines, source}  -- real lyrics
    404  YouTube Music has no lyrics for this track (an answer, not a failure)
    400  malformed video id
    """
    _validate_video_id(video_id)
    cached = _lyrics_cached(video_id)
    if cached is None:
        cached = _fetch_lyrics(video_id)
        if cached.get("available"):
            _lyrics_store(video_id, cached)
    if not cached.get("available"):
        raise HTTPException(
            status_code=404,
            detail="No lyrics are available for this track.",
        )
    return JSONResponse(content={"videoId": video_id, **cached})


def _port_is_free(port: int) -> bool:
    """True if 127.0.0.1:port can be bound right now.

    Deliberately does NOT set SO_REUSEADDR: on Windows that flag permits
    binding over a live listener, which would make every port look free.
    """
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        try:
            probe.bind(("127.0.0.1", port))
            return True
        except OSError:
            return False


def _answers_health(port: int) -> bool:
    """True only if OUR app answers /health on that port.

    A squatter holding the same port accepts the TCP connection but will not
    speak the app's HTTP, so a bare connect() would be a false positive.
    """
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=1.0)
    try:
        conn.request("GET", "/health")
        resp = conn.getresponse()
        body = resp.read(256)
        return resp.status == 200 and b'"ok"' in body
    except OSError:
        return False
    finally:
        conn.close()


def _choose_port() -> int:
    """YTM_PORT when set, otherwise the first free port starting at 8000.

    A backend orphaned by a previous launch keeps 8000 bound. Refusing to
    start there left the frontend reading a port that answered nothing, so
    move over instead of failing.
    """
    explicit = os.environ.get("YTM_PORT")
    if explicit:
        return int(explicit)

    for candidate in range(8000, 8100):
        if _port_is_free(candidate):
            return candidate

    raise RuntimeError("No free port between 8000 and 8099.")


def _publish_when_ready(port: int, timeout: float = 20.0) -> None:
    """Write the port file only once the port actually accepts connections.

    Writing it before uvicorn binds let a backend that died on "address
    already in use" advertise a healthy port: the frontend read it, believed
    the sidecar was up, and every later request failed with "connection
    refused" — which surfaced to the user as a failed sign-in.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        if _answers_health(port):
            break
        time.sleep(0.1)
    else:
        # Never became ready. Leave no port file so the frontend reports a
        # real startup failure instead of talking to nothing.
        logger.error(f"Backend never started listening on port {port}.")
        return

    with open(PORT_FILE, "w") as f:
        f.write(str(port))
    logger.info(f"Published port {port} to {PORT_FILE}")


if __name__ == "__main__":
    port = _choose_port()
    _BOUND_PORT = port

    logger.info(f"Starting backend on port {port}")
    threading.Thread(target=_publish_when_ready, args=(port,), daemon=True).start()
    uvicorn.run(app, host="127.0.0.1", port=port)
