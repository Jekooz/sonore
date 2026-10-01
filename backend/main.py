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

import logging
import os
import tempfile

import uvicorn
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import JSONResponse

from services.ytmusic_client import AuthError, StorageError, ytmusic_service

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
    Headers are stored in the OS keyring only — never a file.
    """
    cookies = payload.get("cookies")
    if not isinstance(cookies, dict) or not cookies:
        raise HTTPException(status_code=400, detail="Body must contain a 'cookies' object.")

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


if __name__ == "__main__":
    # Fixed by default (frontend falls back to 8000 if the sidecar fails to start);
    # YTM_PORT overrides it when 8000 is taken by something else on the machine.
    port = int(os.environ.get("YTM_PORT", "8000"))

    with open(PORT_FILE, "w") as f:
        f.write(str(port))

    logger.info(f"Starting backend on port {port}")
    uvicorn.run(app, host="127.0.0.1", port=port)
