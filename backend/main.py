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
  GET  /library/liked           liked songs
  GET  /search?q=...            search songs / albums / artists / playlists
"""

import http.client
import logging
import os
import re
import shutil
import socket
import subprocess
import tempfile
import threading
import time

import uvicorn
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import JSONResponse

from services.ytmusic_client import (
    REQUIRED_COOKIES,
    AuthError,
    StorageError,
    ytmusic_service,
)

app = FastAPI()
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("ytmusic-backend")

PORT_FILE = os.path.join(tempfile.gettempdir(), "ytmusic_sidecar_port.txt")


@app.get("/health")
def health():
    return JSONResponse(content={"status": "ok"})


# ---------------- auth ----------------


@app.get("/auth/status")
def auth_status():
    try:
        signed_in = ytmusic_service.is_signed_in()
        return JSONResponse(content={"logged_in": signed_in, "error": None})
    except Exception as e:
        logger.exception("auth/status failed")
        return JSONResponse(content={"logged_in": False, "error": str(e)})


@app.post("/auth/cookies")
async def auth_cookies(payload: dict):
    """
    Complete sign-in. Body: {"cookies": {"SID": "...", "__Secure-3PAPISID": "...", ...}}

    The frontend captures these from its embedded browser (WebView2 CookieManager,
    which can read HttpOnly cookies) after the user signs in at music.youtube.com.
    Headers are stored encrypted via Windows DPAPI — never written to disk in
    plaintext.
    """
    cookies = payload.get("cookies")
    if not isinstance(cookies, dict) or not cookies:
        raise HTTPException(status_code=400, detail="Body must contain a 'cookies' object.")

    # Log names only, never values — this is what tells us whether the capture
    # side delivered a complete YouTube session when sign-in does not verify.
    logger.info("Received %d cookies: %s", len(cookies), ", ".join(sorted(cookies)))
    missing = [n for n in REQUIRED_COOKIES if not cookies.get(n)]
    if missing:
        logger.warning("Missing required cookie(s): %s", ", ".join(missing))

    try:
        result = ytmusic_service.store_session(cookies)
    except StorageError as e:
        # StorageError subclasses AuthError, so it must be caught first.
        logger.error("Keyring storage failed: %s", e)
        raise HTTPException(status_code=500, detail=str(e))
    except AuthError as e:
        raise HTTPException(status_code=401, detail=str(e))
    except Exception as e:
        logger.exception("Storing session failed")
        raise HTTPException(status_code=500, detail=f"Could not store session: {e}")

    # Validate the session right away so the user learns immediately if the
    # cookies don't actually work (e.g. signed into the wrong account).
    try:
        account = ytmusic_service.call("get_account_info")
        result["account"] = account
    except Exception as e:
        logger.error(
            "Session stored but YouTube did not treat it as authenticated: %r", e)
        ytmusic_service.clear_session()
        raise HTTPException(
            status_code=401,
            detail=f"Sign-in could not be verified with YouTube Music: {e}",
        )

    return JSONResponse(content=result)


@app.post("/auth/signout")
def auth_signout():
    ytmusic_service.clear_session()
    return JSONResponse(content={"signed_out": True})


# ---------------- account + data ----------------


def _data(method: str, **kwargs):
    """Shared wrapper for authenticated data calls -> 401 on auth problems."""
    try:
        return ytmusic_service.call(method, **kwargs)
    except AuthError as e:
        raise HTTPException(status_code=401, detail=str(e))
    except Exception as e:
        logger.exception("%s failed", method)
        raise HTTPException(status_code=502, detail=f"YouTube Music request failed: {e}")


@app.get("/account")
def account():
    return JSONResponse(content=_data("get_account_info"))


@app.get("/home")
def home():
    rows = _data("get_home", limit=6)
    # Keep only rows that actually have content to render.
    return JSONResponse(content=[r for r in rows if r.get("contents")])


@app.get("/library/playlists")
def library_playlists():
    return JSONResponse(content=_data("get_library_playlists", limit=50))


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


@app.get("/search")
def search(q: str = Query(..., min_length=1)):
    results = _data("search", query=q, limit=20)
    return JSONResponse(content=results)


# ---------------- playback ----------------

# googlevideo URLs are signed and expire in about 6 hours; keep them a little
# less than that so a listening session never starts playing a dead link.
_STREAM_CACHE: dict[str, tuple[str, float]] = {}
_STREAM_TTL_SECONDS = 4 * 60 * 60

# yt-dlp ships as a WinGet exe on this machine; resolve it at import time so a
# missing binary produces one clear 503 instead of an unhandled crash.
_YT_DLP = shutil.which("yt-dlp") or "yt-dlp"

# itag 140 (m4a/AAC) plays through Windows Media Foundation. Prefer it, but
# fall back to whatever audio YouTube serves rather than failing outright.
_AUDIO_FORMAT = "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]/bestaudio"

_VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{6,20}$")


def _resolve_stream(video_id: str) -> str:
    """Resolve a playable audio URL for a video id using yt-dlp.

    Invoked as a subprocess (no shell) with the id passed as a single argv
    element, so the id is never interpreted by a shell.
    """
    now = time.time()
    cached = _STREAM_CACHE.get(video_id)
    if cached and cached[1] > now:
        return cached[0]

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

    lines = [ln.strip() for ln in (proc.stdout or "").splitlines() if ln.strip()]
    if proc.returncode != 0 or not lines:
        err = [ln for ln in (proc.stderr or "").splitlines() if ln.strip()]
        reason = err[-1] if err else f"yt-dlp exited {proc.returncode}"
        logger.error("yt-dlp failed for %s: %s", video_id, reason)
        raise HTTPException(
            status_code=502,
            detail=f"Could not resolve a stream for this track: {reason}",
        )

    url = lines[-1]
    _STREAM_CACHE[video_id] = (url, now + _STREAM_TTL_SECONDS)
    return url


@app.get("/stream/{video_id}")
def stream(video_id: str):
    """Return a short-lived audio URL for the player to fetch directly."""
    if not _VIDEO_ID_RE.fullmatch(video_id):
        raise HTTPException(status_code=400, detail="Invalid video id.")
    return JSONResponse(content={"videoId": video_id, "url": _resolve_stream(video_id)})


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

    logger.info(f"Starting backend on port {port}")
    threading.Thread(target=_publish_when_ready, args=(port,), daemon=True).start()
    uvicorn.run(app, host="127.0.0.1", port=port)
