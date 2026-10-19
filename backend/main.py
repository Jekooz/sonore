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
from datetime import datetime, timezone
from urllib.parse import urlsplit

import uvicorn
from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.responses import JSONResponse

from pydantic import BaseModel, Field
from typing import Literal
from ytmusicapi import YTMusic

from services.browser_auth import (
    BrowserAuthSession,
    detect_default_browser,
)
from services.browser_cookies import (
    cookies_from_firefox,
    find_controllable_browser,
    remove_browser_profile,
)
from services import ranking, recommend
from services.listening import listening_store
from services.ytmusic_client import (
    REQUIRED_COOKIES,
    AuthError,
    StorageError,
    cookies_from_cookie_header,
    install_token_get,
    install_token_set,
    sanitize_account,
    ytmusic_service,
)

app = FastAPI()
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("ytmusic-backend")

# The published port file. Defaults to %LOCALAPPDATA%\Sonore\sidecar_port.txt
# (per-user, outside the app folder and %TEMP%, so a cleaner for temp files
# cannot delete it while the service runs). YTM_PORT_FILE overrides the path so
# an isolated instance -- a test, or a second copy on the same machine -- can
# publish without touching the shared file and without disturbing a live app.
_SONORE_STATE_DIR = os.path.join(
    os.environ.get("LOCALAPPDATA", tempfile.gettempdir()), "Sonore"
)
PORT_FILE = os.environ.get("YTM_PORT_FILE") or os.path.join(
    _SONORE_STATE_DIR, "sidecar_port.txt"
)

# The port file publishing below needs no in-process record of the bound port:
# it is passed directly to the publisher thread.


def _drop_stale_port_file() -> None:
    """Remove a port file left behind by a previous run.

    Best-effort, and deliberately run before uvicorn binds: a reader that finds
    the old file must not be sent to a port this instance is not listening on.
    """
    try:
        os.remove(PORT_FILE)
    except OSError:
        pass


# The install (or source checkout) root: backend\main.py, so one level up is the
# folder the installer stages yt-dlp.exe into.
_APP_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


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


def _validate_and_store(
    cookies: dict, source: str, extra_headers: dict | None = None
) -> dict:
    """
    Shared completion path for every cookie source (browser capture or paste
    hand-off). Gate on required session cookies, confirm
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
        # The cookie-only path keeps its original single-argument shape so every
        # existing caller (and its tests) sees the same contract; extras are only
        # passed when the caller actually supplied browser headers.
        if extra_headers:
            account = ytmusic_service.verify_candidate(cookies, extra_headers)
        else:
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
        if extra_headers:
            result = ytmusic_service.store_session(cookies, extra_headers)
        else:
            result = ytmusic_service.store_session(cookies)
    except StorageError as e:
        logger.error("Credential storage failed: %s", e)
        raise HTTPException(status_code=500, detail="Could not store the session locally.")
    except Exception as e:
        logger.exception("Storing session failed")
        raise HTTPException(status_code=500, detail=f"Could not store session: {e}")

    result["account"] = account
    return result


@app.post("/auth/cookies")
async def auth_cookies(payload: dict):
    """
    Complete sign-in. Body: {"cookies": {"SID": "...", "__Secure-3PAPISID": "...", ...}}

    Kept for programmatic/diagnostic use; the UI flow now goes through
    /auth/browser/start. Same validation + storage path.
    """
    cookies = payload.get("cookies")
    if not isinstance(cookies, dict) or not cookies:
        raise HTTPException(status_code=400, detail="Body must contain a 'cookies' object.")
    return JSONResponse(content=_validate_and_store(cookies, "auth/cookies"))


@app.post("/auth/signout")
def auth_signout():
    ytmusic_service.clear_session()
    # The sign-in window kept its own Google session in a profile this app owns.
    # Signing out must not leave that behind, or the next "Sign in" would
    # silently reuse the account the user just left.
    remove_browser_profile()
    return JSONResponse(content={"signed_out": True})


# ---------------- browser-based sign-in ----------------

# The active BrowserAuthSession for this process, if a sign-in is in flight.
_browser_session: BrowserAuthSession | None = None
_browser_session_lock = threading.Lock()

# Where a validated jar is handed to the attempt that is waiting for it.
# Delivered per-session (BrowserAuthSession.deliver) rather than through a
# shared slot: with a shared slot, a superseded attempt's poll loop could
# consume the jar meant for the live one and the app waited forever.


def _deliver_to_current_attempt(cookies: dict) -> None:
    with _browser_session_lock:
        session = _browser_session
    if session is not None:
        session.deliver(cookies)


def _clear_browser_session() -> None:
    global _browser_session
    with _browser_session_lock:
        if _browser_session is not None:
            _browser_session.cancel()
        _browser_session = None


def _complete_browser_capture(cookies: dict, source: str) -> None:
    """Validate + store a session the browser capture produced.

    Verification runs BEFORE anything is stored (M2), so a stale, partial or
    wrong-account jar fails this attempt while a working session stays exactly
    as it was. Raising here is what the attempt turns into its failed state;
    HTTPException carries the user-facing wording in .detail.
    """
    _validate_and_store(cookies, source)


# ---------------- per-install API token ----------------

# One random token per install, stored encrypted next to the session material.
# Every endpoint that returns account data or a stream requires it (header
# `X-Sonore-Token`), so a stray local caller or a forged web origin cannot
# reach the account even when loopback itself is allowed. It never rotates
# while the install exists; learning it requires reading the encrypted file or
# being shown it in the app's Settings -> Account.
_install_token: str | None = None
_install_token_lock = threading.Lock()


def _ensure_install_token() -> str:
    """Generate the per-install token once and keep it encrypted at rest."""
    global _install_token
    with _install_token_lock:
        if _install_token is None:
            stored = install_token_get()
            if stored:
                _install_token = stored
            else:
                _install_token = secrets.token_urlsafe(32)
                try:
                    install_token_set(_install_token)
                except StorageError as e:
                    # Encryption cannot run here (or at all): keep the token in
                    # memory for this session instead of refusing to start.
                    logger.warning("Install token could not be stored (%s).", e)
        return _install_token


def _require_install_token(request: Request) -> str | None:
    """Why this caller must not use a locked endpoint, or None."""
    provided = request.headers.get("X-Sonore-Token")
    if not provided:
        return "The Sonore API token is required."
    try:
        expected = _ensure_install_token()
    except StorageError:
        return "The API token is unavailable."
    if not secrets.compare_digest(provided, expected):
        return "The Sonore API token is not valid."
    return None


def _locked(request: Request) -> tuple[int, str] | None:
    """Locality first (Host + Origin), then the per-install token.

    Returns (status, detail) when the caller must be refused, or None.
    """
    reason = _non_loopback_rejection(request)
    if reason is not None:
        return 403, reason
    reason = _require_install_token(request)
    if reason is not None:
        return 401, reason
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
    """The browser sign-in will drive, for the UI's prompt text.

    The window a sign-in opens is a controlled Edge/Chrome -- a real browser, so
    Google signs in normally. Only when the machine has neither does sign-in
    fall back to the default browser plus the paste-headers path.
    """
    found = find_controllable_browser()
    browser = found[0] if found else detect_default_browser()
    return JSONResponse(content={"browser": browser})


@app.get("/auth/install-token")
def auth_install_token(request: Request):
    """
    The per-install API token, for bootstrapping callers.

    No token is needed to read it -- it IS the secret being fetched -- so this
    is the one endpoint the app calls before it knows the token (and the one
    the Settings screen shows with a copy button). Locality is still enforced:
    only this machine's loopback may ask.
    """
    reason = _non_loopback_rejection(request)
    if reason is not None:
        logger.warning("Rejected auth/install-token: %s", reason)
        raise HTTPException(status_code=403, detail=reason)

    return JSONResponse(content={"install_token": _ensure_install_token()})


@app.post("/auth/browser/start")
def auth_browser_start(payload: dict | None = None):
    """
    Start a sign-in. The sidecar owns it end to end, so there is exactly one
    window and no extension to install:

      * an already signed-in Firefox is read straight from disk (no window),
      * otherwise Edge/Chrome opens in a profile this app owns, the user signs
        in there, and the session is read over the DevTools protocol.

    With {"open_browser": false} nothing is opened and nothing is read -- the
    attempt only waits, which is what the Settings paste-headers fallback needs.

    The UI follows along via /auth/browser/status (2 s poll, 3 min timeout).
    """
    global _browser_session

    _clear_browser_session()
    # A fresh session starts with an empty hand-off slot of its own, so a jar
    # left over from a cancelled or timed-out attempt cannot leak into this one.

    open_browser = not (
        isinstance(payload, dict) and payload.get("open_browser") is False
    )
    session = BrowserAuthSession(
        completer=_complete_browser_capture,
        # The zero-click read belongs to a real sign-in only: the paste
        # fallback must not be short-circuited by a Firefox session.
        direct_reader=cookies_from_firefox if open_browser else None,
    )
    with _browser_session_lock:
        _browser_session = session

    session.start(open_browser=open_browser)
    return JSONResponse(content=session.status())


@app.get("/auth/browser/status")
def auth_browser_status():
    if _browser_session is None:
        found = find_controllable_browser()
        return JSONResponse(
            content={
                "state": "idle",
                "browser": found[0] if found else detect_default_browser(),
                "error": None,
            }
        )
    return JSONResponse(content=_browser_session.status())


@app.post("/auth/browser/cancel")
def auth_browser_cancel():
    _clear_browser_session()
    return JSONResponse(content={"state": "cancelled"})


# ---------------- browser hand-off (loopback-only) ----------------

# Payload bounds for /auth/handoff: generous for a real browser jar (hundreds
# of cookies) and far below anything worth allocating for, checked before the
# body is parsed. No cookie or header VALUE is ever logged -- counts and
# rejection reasons only, same rule as above.
_MAX_HANDOFF_BYTES = 64 * 1024
_MAX_HANDOFF_ENTRIES = 256
_MAX_HANDOFF_VALUE = 8 * 1024
_MAX_HANDOFF_KEY = 256

# Hosts that count as "this machine". ``[::1]`` is the bracketed form a Host
# header uses for IPv6, kept alongside the bare form urlsplit yields.
_LOOPBACK_HOSTS = frozenset({"127.0.0.1", "localhost", "::1", "[::1]"})


def _hostname_of(host_header: str) -> str:
    """Hostname from a Host header, with port and IPv6 brackets removed."""
    value = host_header.strip().lower()
    if value.startswith("["):
        end = value.find("]")
        return value[: end + 1] if end != -1 else value
    return value.rsplit(":", 1)[0] if ":" in value else value


def _non_loopback_rejection(request: Request) -> str | None:
    """Why this request must not reach the hand-off, or None when it may.

    Two independent checks because neither header alone is sufficient:

    * Host catches DNS rebinding -- a domain that resolves to loopback still
      announces itself by name, and must not be treated as local.
    * Origin catches a web page POSTing in from another origin. ``null`` is
      rejected on purpose: sandboxed frames and data: URLs produce it, so it
      is forgeable by exactly the pages this check exists to exclude.

    The app's HTTP client sends no Origin at all (native callers do not).
    """
    host = request.headers.get("host")
    if host:
        name = _hostname_of(host)
        if name not in _LOOPBACK_HOSTS:
            return f"Host '{name}' is not a loopback address."

    origin = request.headers.get("origin")
    if origin:
        value = origin.strip().lower()
        scheme = value.split(":", 1)[0] if ":" in value else ""
        if value == "null":
            return "Origin 'null' is not a loopback origin."
        if scheme in ("http", "https"):
            hostname = urlsplit(value).hostname
            if hostname not in _LOOPBACK_HOSTS:
                return f"Origin '{value}' is not a loopback origin."
        else:
            return f"Origin '{value}' is not allowed."
    return None


def _validated_handoff_payload(payload: object) -> tuple[dict, dict]:
    """Structural check: return (cookies, headers), both flat string maps.

    Checked before the attempt's state, so a malformed body is reported as a
    malformed body rather than as "no sign-in in progress".
    """
    if not isinstance(payload, dict):
        raise HTTPException(status_code=400, detail="Body must be a JSON object.")

    cookies = payload.get("cookies") or {}
    headers = payload.get("headers") or {}
    if not isinstance(cookies, dict) or not isinstance(headers, dict):
        raise HTTPException(
            status_code=400,
            detail="'cookies' and 'headers' must both be JSON objects.",
        )

    # Header names are case-insensitive everywhere else; normalising once here
    # means the passthrough lookup and a pasted devtools block agree.
    headers = {k.lower(): v for k, v in headers.items() if isinstance(k, str)}

    for label, mapping in (("cookies", cookies), ("headers", headers)):
        if len(mapping) > _MAX_HANDOFF_ENTRIES:
            raise HTTPException(
                status_code=400,
                detail=f"Too many {label} entries (limit {_MAX_HANDOFF_ENTRIES}).",
            )
        for key, value in mapping.items():
            if (
                not isinstance(key, str)
                or len(key) > _MAX_HANDOFF_KEY
                or not isinstance(value, str)
                or len(value) > _MAX_HANDOFF_VALUE
            ):
                raise HTTPException(
                    status_code=400,
                    detail=f"Each {label} entry must be a short text value.",
                )
    return cookies, headers


@app.post("/auth/handoff")
async def auth_handoff(request: Request):
    """
    Browser-session hand-off, reachable only from this machine.

    Body: {"cookies": {...}, "headers": {"user-agent": "...", ...}} -- both
    halves optional, at least one must carry a session. The Settings "paste
    request headers" fallback sends headers only; the cookie line inside them is
    recovered and takes the same path a captured jar does.

    Order of checks, all before anything is stored:
      1. loopback Host/Origin        -> 403 (non-local caller)
      2. declared/actual body size   -> 413
      3. JSON parse + shape          -> 400
      4. an attempt is actually waiting -> 409
      5. the per-install API token      -> 401
      6. required cookies present + YouTube accepts the candidate (one cheap
         get_account_info) -> 422/401, never storing a bad hand-off

    Then it stores through the same encrypted path as every other source.
    Cookie and header VALUES are never logged.
    """
    reason = _non_loopback_rejection(request)
    if reason is not None:
        logger.warning("Rejected hand-off: %s", reason)
        raise HTTPException(status_code=403, detail=reason)

    declared = request.headers.get("content-length", "")
    if declared.isdigit() and int(declared) > _MAX_HANDOFF_BYTES:
        logger.warning("Rejected hand-off: body of %s bytes is too large", declared)
        raise HTTPException(
            status_code=413,
            detail=f"Body is too large (limit {_MAX_HANDOFF_BYTES} bytes).",
        )
    raw = await request.body()
    if len(raw) > _MAX_HANDOFF_BYTES:
        logger.warning("Rejected hand-off: body of %s bytes is too large", len(raw))
        raise HTTPException(
            status_code=413,
            detail=f"Body is too large (limit {_MAX_HANDOFF_BYTES} bytes).",
        )

    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        raise HTTPException(status_code=400, detail="Body must be valid JSON.")

    cookies, headers = _validated_handoff_payload(payload)

    # Order: is anything waiting, then is the caller authorised, then is there a
    # session to hand over. Nothing is stored until all of them pass.
    if not _sign_in_pending():
        logger.warning("Rejected hand-off: no sign-in in progress.")
        raise HTTPException(
            status_code=409,
            detail="No sign-in is in progress. Start sign-in from the app first.",
        )

    locked = _locked(request)
    if locked is not None:
        status, detail = locked
        logger.warning("Rejected hand-off: %s", detail)
        raise HTTPException(status_code=status, detail=detail)

    if not cookies and "cookie" in headers:
        cookies = cookies_from_cookie_header(headers["cookie"])
    if not cookies and headers:
        raise HTTPException(
            status_code=400,
            detail="The pasted request headers must include a 'cookie:' line.",
        )
    # An empty payload from both directions lands in the shared validation, so
    # the screen gets the "not signed in" wording with the real reason.

    try:
        result = _validate_and_store(cookies, "auth/handoff", headers)
    except HTTPException as e:
        if _browser_session is not None:
            _browser_session.fail(e.detail)
        raise

    # Same wiring as a captured jar: the waiting poll loop picks it up,
    # marks the attempt successful and drops its own reference afterwards.
    _deliver_to_current_attempt(cookies)

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
def account(request: Request):
    locked = _locked(request)
    if locked is not None:
        status, detail = locked
        raise HTTPException(status_code=status, detail=detail)
    # Sanitized here as well as in verify_candidate: the service's `accountName`
    # has answered with one of its own chrome labels ("Home") on a real session,
    # and Settings must never show that as the signed-in account.
    return JSONResponse(content=sanitize_account(_data("get_account_info")))


@app.get("/home")
def home(request: Request):
    locked = _locked(request)
    if locked is not None:
        status, detail = locked
        raise HTTPException(status_code=status, detail=detail)
    rows = _data("get_home", limit=6)
    # Keep only rows that actually have content to render.
    return JSONResponse(content=[r for r in rows if r.get("contents")])


@app.get("/library/playlists")
def library_playlists(request: Request):
    locked = _locked(request)
    if locked is not None:
        status, detail = locked
        raise HTTPException(status_code=status, detail=detail)
    playlists = _data("get_library_playlists", limit=50) or []
    normalized = []
    for p in playlists:
        item = dict(p)
        author_val = p.get("author") or p.get("authors") or p.get("owner")
        item["author"] = _credit_names(author_val) if author_val else ""
        normalized.append(item)
    return JSONResponse(content=normalized)


@app.get("/library/artists")
def library_artists(request: Request):
    locked = _locked(request)
    if locked is not None:
        status, detail = locked
        raise HTTPException(status_code=status, detail=detail)
    return JSONResponse(content=_data("get_library_artists", limit=50))


@app.get("/library/albums")
def library_albums(request: Request):
    locked = _locked(request)
    if locked is not None:
        status, detail = locked
        raise HTTPException(status_code=status, detail=detail)
    return JSONResponse(content=_data("get_library_albums", limit=50))


@app.get("/library/songs")
def library_songs(request: Request):
    locked = _locked(request)
    if locked is not None:
        status, detail = locked
        raise HTTPException(status_code=status, detail=detail)
    return JSONResponse(content=_data("get_library_songs", limit=100))


@app.get("/library/subscriptions")
def library_subscriptions(request: Request):
    locked = _locked(request)
    if locked is not None:
        status, detail = locked
        raise HTTPException(status_code=status, detail=detail)
    return JSONResponse(content=_data("get_library_subscriptions", limit=50))


@app.get("/library/liked")
def library_liked(request: Request):
    locked = _locked(request)
    if locked is not None:
        status, detail = locked
        raise HTTPException(status_code=status, detail=detail)
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
def album_detail(request: Request, browse_id: str):
    """An album as a collection: real metadata + real track list (get_album)."""
    locked = _locked(request)
    if locked is not None:
        status, detail = locked
        raise HTTPException(status_code=status, detail=detail)
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
def playlist_detail(request: Request, playlist_id: str):
    """A playlist as a collection: real metadata + real track list (get_playlist)."""
    locked = _locked(request)
    if locked is not None:
        status, detail = locked
        raise HTTPException(status_code=status, detail=detail)
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
def artist_detail(request: Request, channel_id: str):
    """An artist as a collection: their real top songs, playable as a tracklist.

    get_artist() nests the songs under {"songs": {"results": [...]}}; each row
    already carries a videoId, so the artist page can play any track the user
    picks. Albums/singles live under their own keys and are not tracks, so they
    are not flattened in here.
    """
    locked = _locked(request)
    if locked is not None:
        status, detail = locked
        raise HTTPException(status_code=status, detail=detail)
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
    request: Request,
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
    locked = _locked(request)
    if locked is not None:
        status, detail = locked
        raise HTTPException(status_code=status, detail=detail)
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
    request: Request,
    videoId: str = Query(..., description="Seed video id"),
    limit: int = Query(30, ge=1, le=MAX_CANDIDATES),
):
    """Start Radio: genuine YT Music radio (+ related) for one seed song."""
    locked = _locked(request)
    if locked is not None:
        status, detail = locked
        raise HTTPException(status_code=status, detail=detail)
    _validate_video_id(videoId)
    payload = _ranked_candidates(videoId, limit, exclude=set())
    payload["source"] = "radio"
    return JSONResponse(content=payload)


@app.get("/recommendations")
def recommendations(
    request: Request,
    seed: str = Query(..., description="Current video id"),
    limit: int = Query(12, ge=1, le=MAX_CANDIDATES),
    exclude: str | None = Query(
        default=None,
        description="Comma-separated videoIds already in the queue (bounded)",
    ),
):
    """Autoplay: ranked candidates to append while the queue runs low."""
    locked = _locked(request)
    if locked is not None:
        status, detail = locked
        raise HTTPException(status_code=status, detail=detail)
    _validate_video_id(seed)
    blocked = _parse_exclude(exclude)
    payload = _ranked_candidates(seed, limit, exclude=blocked)
    payload["source"] = "recommendations"
    return JSONResponse(content=payload)


@app.post("/listening/events")
def listening_events(request: Request, event: ListeningEventIn):
    """
    Store one aggregated playback event (not a position tick). The store
    validates again, clamps numbers and caps growth; no secrets are kept.
    """
    locked = _locked(request)
    if locked is not None:
        status, detail = locked
        raise HTTPException(status_code=status, detail=detail)
    try:
        total = listening_store.record(event.model_dump())
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    return JSONResponse(content={"recorded": True, "events": total})


@app.get("/listening/history")
def listening_history(request: Request, limit: int = Query(30, ge=1, le=100)):
    """
    The most recent distinct tracks this app played, newest first.

    This is the app's own record (the same store the ranker reads), not a
    claim about the account's YouTube Music history, and it holds no session
    data — only video ids, titles, artists and playback numbers.
    """
    locked = _locked(request)
    if locked is not None:
        status, detail = locked
        raise HTTPException(status_code=status, detail=detail)
    entries = listening_store.recent_plays(limit)
    return JSONResponse(content={"entries": entries, "count": len(entries)})


@app.post("/ratings")
def ratings(request: Request, payload: RatingIn):
    """
    Genuine like / dislike / unlike via ytmusicapi's rate_song. The explicit
    rating is also remembered locally so the ranker can weigh it — distinct
    from adding/removing the song in the library (a different provider op
    this endpoint deliberately does not perform).
    """
    locked = _locked(request)
    if locked is not None:
        status, detail = locked
        raise HTTPException(status_code=status, detail=detail)
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
def set_subscription(request: Request, payload: SubscriptionIn):
    """Follow or unfollow one artist channel.

    A genuine account change — the same operation the YouTube Music UI performs.
    ytmusicapi's ``subscribe_artist`` takes one channel; unsubscribing goes
    through ``unsubscribe_artists`` (a list), which is the only remove method the
    library exposes. The plural subscribe form is deprecated upstream, so it is
    deliberately not used.
    """
    locked = _locked(request)
    if locked is not None:
        status, detail = locked
        raise HTTPException(status_code=status, detail=detail)
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

# yt-dlp: prefer a copy this app updated in %LOCALAPPDATA%\Sonore\bin\, then the
# copy the installer ships beside the app (the sidecar's working directory is
# backend\, so PATH alone would never find it), then PATH, and finally the bare
# name so a missing binary produces one clear 503.
_YT_DLP_DIR = os.path.join(_SONORE_STATE_DIR, "bin")
_YT_DLP_UPDATED = os.path.join(_YT_DLP_DIR, "yt-dlp.exe")
_YT_DLP_BUNDLED = os.path.join(_APP_ROOT, "yt-dlp.exe")


def _resolve_yt_dlp() -> str:
    """The yt-dlp to run: an updated copy, else the bundled one, else PATH."""
    if os.path.exists(_YT_DLP_UPDATED):
        return _YT_DLP_UPDATED
    if os.path.exists(_YT_DLP_BUNDLED):
        return _YT_DLP_BUNDLED
    return shutil.which("yt-dlp") or "yt-dlp"


_YT_DLP = _resolve_yt_dlp()

# itag 140 (m4a/AAC) plays through Windows Media Foundation. Prefer it, but
# fall back to whatever audio YouTube serves rather than failing outright.
_AUDIO_FORMAT = "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]/bestaudio"

# yt-dlp auto-update: at most once per day, in the background, results recorded
# in %LOCALAPPDATA%\Sonore\update_state.json for Settings to report.
_UPDATE_STATE_FILE = os.path.join(_SONORE_STATE_DIR, "update_state.json")
_UPDATE_CHECK_SECONDS = 24 * 60 * 60
_updating = False
_updating_lock = threading.Lock()


def _update_due() -> bool:
    """True when the once-per-day background check may run again."""
    try:
        with open(_UPDATE_STATE_FILE, encoding="utf-8") as f:
            state = json.load(f)
    except (OSError, ValueError):
        return True
    last = state.get("last_check")
    if not last:
        return True
    try:
        last_time = datetime.fromisoformat(str(last))
    except ValueError:
        return True
    return time.time() - last_time.timestamp() > _UPDATE_CHECK_SECONDS


def _read_update_state() -> dict:
    try:
        with open(_UPDATE_STATE_FILE, encoding="utf-8") as f:
            state = json.load(f)
    except (OSError, ValueError):
        return {}
    if not isinstance(state, dict):
        return {}
    return state


def _record_update_state(
    *,
    ok: bool,
    version: str | None = None,
    error: str | None = None,
) -> None:
    state = {
        "last_check": datetime.now(timezone.utc).isoformat(),
        "ok": ok,
        "version": version,
        "error": error,
    }
    tmp_path = _UPDATE_STATE_FILE + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(state, f)
    os.replace(tmp_path, _UPDATE_STATE_FILE)


def _fetch_yt_dlp_update(dest_dir: str) -> str:
    """
    Download the latest yt-dlp.exe from GitHub into *dest_dir* and return its
    version. Monkeypatched by tests so no network is needed.
    """
    import urllib.request

    with urllib.request.urlopen(
        "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest", timeout=30
    ) as resp:
        release = json.loads(resp.read().decode("utf-8"))
    asset = next(
        (a for a in (release or {}).get("assets", []) if a.get("name") == "yt-dlp.exe"),
        None,
    )
    if not asset or not asset.get("browser_download_url"):
        raise RuntimeError("The latest yt-dlp release has no yt-dlp.exe asset.")
    os.makedirs(dest_dir, exist_ok=True)
    tmp_path = os.path.join(dest_dir, "yt-dlp.exe.new")
    with urllib.request.urlopen(asset["browser_download_url"], timeout=120) as src, open(
        tmp_path, "wb"
    ) as dst:
        shutil.copyfileobj(src, dst)
    final_path = os.path.join(dest_dir, "yt-dlp.exe")
    os.replace(tmp_path, final_path)
    # Forget the resolved binary so the update takes effect at once.
    global _YT_DLP
    _YT_DLP = final_path
    return _yt_dlp_version(final_path) or "unknown"


def _do_yt_dlp_update() -> None:
    """Background worker: check once per day, refresh yt-dlp when due."""
    global _updating
    with _updating_lock:
        if _updating:
            return
        _updating = True
    try:
        if not _update_due():
            _record_update_state(ok=True, version=_yt_dlp_version(_YT_DLP))
            return
        version = _fetch_yt_dlp_update(_YT_DLP_DIR)
        logger.info("yt-dlp updated to %s in %s", version, _YT_DLP_DIR)
        _record_update_state(ok=True, version=version)
    except Exception as e:
        logger.warning("yt-dlp background update failed: %s", e)
        _record_update_state(ok=False, error=type(e).__name__)
    finally:
        with _updating_lock:
            _updating = False


def _maybe_start_yt_dlp_update_check() -> None:
    """Kick off the at-most-once-per-day background update check at launch."""
    threading.Thread(target=_do_yt_dlp_update, daemon=True).start()


def _yt_dlp_version(binary: str) -> str | None:
    """The upstream version of *binary*, or None when it cannot be read."""
    try:
        proc = subprocess.run(
            [binary, "--version"],
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode == 0:
        version = (proc.stdout or "").strip()
        return version or None
    return None


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
def prefetch(request: Request, video_id: str):
    """Warm the stream-URL cache for a video id (fire-and-forget, bounded)."""
    locked = _locked(request)
    if locked is not None:
        status, detail = locked
        raise HTTPException(status_code=status, detail=detail)
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
            detail=(
                "The playback engine (yt-dlp) is not installed. "
                "Update it in Settings > Playback, or place yt-dlp.exe in "
                "%LOCALAPPDATA%/Sonore/bin/."
            ),
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
def stream(request: Request, video_id: str):
    """Return a short-lived audio URL for the player to fetch directly."""
    locked = _locked(request)
    if locked is not None:
        status, detail = locked
        raise HTTPException(status_code=status, detail=detail)
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
def lyrics(request: Request, video_id: str):
    """Real lyrics for the current track.

    200  {available: true, synced, lines, source}  -- real lyrics
    404  YouTube Music has no lyrics for this track (an answer, not a failure)
    400  malformed video id
    """
    locked = _locked(request)
    if locked is not None:
        status, detail = locked
        raise HTTPException(status_code=status, detail=detail)
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


@app.get("/playback/engine")
def playback_engine(request: Request):
    """The playback engine (yt-dlp) in use: version, source and update state."""
    locked = _locked(request)
    if locked is not None:
        status, detail = locked
        raise HTTPException(status_code=status, detail=detail)
    binary = _YT_DLP
    if binary == _YT_DLP_UPDATED:
        source = "updated"
    elif binary == _YT_DLP_BUNDLED:
        source = "bundled"
    elif shutil.which("yt-dlp"):
        source = "path"
    else:
        source = "bundled"
    return JSONResponse(
        content={
            "version": _yt_dlp_version(binary),
            "source": source,
            "path": binary,
            "update": _read_update_state(),
        }
    )


@app.post("/playback/engine/update")
def playback_engine_update(request: Request):
    """Refresh the playback engine to the latest yt-dlp (runs in the background)."""
    global _updating
    locked = _locked(request)
    if locked is not None:
        status, detail = locked
        raise HTTPException(status_code=status, detail=detail)

    with _updating_lock:
        if _updating:
            return JSONResponse(
                status_code=202,
                content={"update": "busy", "detail": "An update is already in progress."},
            )
        _updating = True

    def worker() -> None:
        try:
            version = _fetch_yt_dlp_update(_YT_DLP_DIR)
            logger.info("yt-dlp updated on demand to %s in %s", version, _YT_DLP_DIR)
            _record_update_state(ok=True, version=version)
        except Exception as e:
            logger.warning("yt-dlp on-demand update failed: %s", e)
            _record_update_state(ok=False, error=str(e) or type(e).__name__)
        finally:
            with _updating_lock:
                _updating = False

    threading.Thread(target=worker, daemon=True).start()
    return JSONResponse(status_code=202, content={"update": "started"})


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
    _drop_stale_port_file()
    port = _choose_port()

    logger.info(f"Starting backend on port {port}")
    threading.Thread(target=_publish_when_ready, args=(port,), daemon=True).start()
    # At most once per day, in the background: keep the playback engine current.
    _maybe_start_yt_dlp_update_check()
    uvicorn.run(app, host="127.0.0.1", port=port)
