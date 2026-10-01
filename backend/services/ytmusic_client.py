"""
YouTube Music backend service.

Authentication model — "Sign in with Google" inside the app:
  1. The frontend shows an embedded WebView2 at https://music.youtube.com where the
     user signs in with their normal Google account (no device codes, no console).
  2. Once signed in, the frontend pulls the browser cookies for that domain via the
     WebView2 CookieManager (works for HttpOnly cookies like __Secure-3PAPISID,
     which document.cookie cannot see) and POSTs them to /auth/cookies.
  3. The backend builds the ytmusicapi "browser auth" header set (cookie + a
     SAPISIDHASH authorization header that ytmusicapi recomputes on every request,
     exactly like music.youtube.com does in a normal browser) and stores it in the
     Windows Credential Locker via keyring. Cookies are never written to disk.

This is the same auth mechanism as `ytmusicapi`'s browser setup, automated.
Verified against ytmusicapi 1.12.3 source:
  - ytmusicapi/ytmusic.py:  AuthType.BROWSER requires base_headers["cookie"] and
    recomputes headers["authorization"] = get_authorization(sapisid + " " + origin)
    on each request (SAPISIDHASH <ts>_<sha1(ts + " " + sapisid + " " + origin)>).
  - ytmusicapi/helpers.py:  sapisid_from_cookie() reads the __Secure-3PAPISID cookie.
  - ytmusicapi/auth/auth_parse.py: a dict containing "cookie" + "authorization"
    (SAPISIDHASH) is treated as BROWSER auth; no OAuthCredentials needed.
"""

import json
import logging
import threading

import keyring
from ytmusicapi import YTMusic

logger = logging.getLogger("ytmusic-backend")

YTM_SERVICE_NAME = "ytmusic_client"

# Origin used for the SAPISIDHASH authorization header. Must match the origin the
# cookies belong to (music.youtube.com) or Google rejects the request.
YTM_ORIGIN = "https://music.youtube.com"

# Cookie names required for ytmusicapi browser auth. __Secure-3PAPISID is what
# ytmusicapi's sapisid_from_cookie() extracts; __Secure-1PAPISID improves
# compatibility on some accounts; SID/SAPISID/HPSIDE are standard session cookies.
REQUIRED_COOKIES = ("__Secure-3PAPISID", "SAPISID", "SID")
USEFUL_COOKIES = (
    "__Secure-1PAPISID",
    "__Secure-1PSID",
    "__Secure-3PSID",
    "HSID",
    "SSID",
    "APISID",
    "SAPISID",
    "LOGIN_INFO",
    "VISITOR_INFO1_LIVE",
    "YSC",
    "__Secure-LOGIN_INFO",
)

# Library/scope limits for the data endpoints (kept small enough to stay snappy).
LIMITS = {
    "home_rows": 6,
    "playlists": 50,
    "artists": 50,
    "albums": 50,
    "songs": 100,
    "subscriptions": 50,
    "liked_songs": 300,
}


class AuthError(Exception):
    """Raised when sign-in data is missing/invalid or no session exists."""


class StorageError(AuthError):
    """Raised when the OS keyring itself is unavailable or refuses writes."""


def _build_cookie_header(cookie_map: dict) -> str:
    """Serialize the cookies we know into a single Cookie header value."""
    parts = []
    for name in dict.fromkeys(REQUIRED_COOKIES + USEFUL_COOKIES):
        value = cookie_map.get(name)
        if value:
            parts.append(f"{name}={value}")
    # Also append any other cookies that arrived (don't lose extras Google sets).
    known = set(REQUIRED_COOKIES + USEFUL_COOKIES)
    for name, value in cookie_map.items():
        if name not in known and value:
            parts.append(f"{name}={value}")
    return "; ".join(parts)


def build_auth_headers(cookie_map: dict) -> dict:
    """
    Build the ytmusicapi browser-auth header dict from captured cookies.

    Raises AuthError if a required cookie is missing. The authorization header
    format (SAPISIDHASH) is what ytmusicapi checks for to classify this as
    BROWSER auth; it recomputes the timestamped hash itself on every request.
    """
    missing = [name for name in REQUIRED_COOKIES if not cookie_map.get(name)]
    if missing:
        raise AuthError(
            "Google sign-in incomplete: missing cookie(s) " + ", ".join(missing)
            + ". Make sure you are fully signed in to music.youtube.com in the app window."
        )

    cookie_header = _build_cookie_header(cookie_map)
    # A placeholder SAPISIDHASH is required so ytmusicapi classifies the headers as
    # BROWSER auth; ytmusicapi recomputes it (fresh timestamp + hash) per request.
    return {
        "cookie": cookie_header,
        "authorization": "SAPISIDHASH 0_placeholder",
        "x-origin": YTM_ORIGIN,
        "origin": YTM_ORIGIN,
        "user-agent": (
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
            "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
        ),
    }


class YtmusicService:
    """
    Holds the sign-in session (headers in keyring) and provides YTMusic clients.

    A new YTMusic instance is built from stored headers when needed and cached
    until the session changes (sign-out / re-login). YTMusic is not guaranteed
    thread-safe, so access is guarded by a lock.
    """

    def __init__(self):
        self._client = None
        self._lock = threading.Lock()

    # ---------- session storage ----------

    @staticmethod
    def _keyring_get() -> str | None:
        try:
            return keyring.get_password(YTM_SERVICE_NAME, "auth_headers")
        except keyring.errors.KeyringError as e:
            # E.g. no OS credential backend (bare Linux). Degrade to signed-out
            # instead of making every endpoint error.
            logger.warning("OS keyring unavailable (%s); treating as signed out.", e)
            return None

    @staticmethod
    def _keyring_set(value: str) -> None:
        try:
            keyring.set_password(YTM_SERVICE_NAME, "auth_headers", value)
        except keyring.errors.KeyringError as e:
            raise StorageError(f"Could not store credentials in the OS keyring: {e}") from e

    @staticmethod
    def _keyring_delete() -> None:
        try:
            keyring.delete_password(YTM_SERVICE_NAME, "auth_headers")
        except keyring.errors.PasswordDeleteError:
            pass  # nothing stored
        except keyring.errors.KeyringError as e:
            logger.warning("OS keyring unavailable during sign-out (%s).", e)

    def store_session(self, cookie_map: dict) -> dict:
        """Validate cookies, store headers in the OS keyring, reset the client."""
        headers = build_auth_headers(cookie_map)
        self._keyring_set(json.dumps(headers))
        with self._lock:
            self._client = None  # force rebuild on next use
        return {"signed_in": True}

    def get_headers(self) -> dict | None:
        stored = self._keyring_get()
        if not stored:
            return None
        try:
            headers = json.loads(stored)
        except json.JSONDecodeError:
            logger.error("Stored auth headers are corrupt; ignoring.")
            return None
        if not isinstance(headers, dict) or "cookie" not in headers:
            return None
        return headers

    def clear_session(self) -> None:
        self._keyring_delete()
        with self._lock:
            self._client = None

    # ---------- client access ----------

    def _get_client(self) -> YTMusic:
        with self._lock:
            if self._client is not None:
                return self._client
            headers = self.get_headers()
            if headers is None:
                raise AuthError("Not signed in.")
            try:
                self._client = YTMusic(auth=headers)
            except Exception as e:
                logger.exception("Failed to build YTMusic client from stored session")
                raise AuthError(f"Could not initialize YouTube Music client: {e}") from e
            return self._client

    def is_signed_in(self) -> bool:
        return self.get_headers() is not None

    def call(self, method: str, *args, **kwargs):
        """
        Call a YTMusic method by name. Translates auth errors into AuthError so
        the API layer can return a clean 401 instead of a 500 stack trace.
        """
        client = self._get_client()
        try:
            fn = getattr(client, method)
            return fn(*args, **kwargs)
        except Exception as e:
            msg = str(e)
            if "authentication" in msg.lower() or "not signed in" in msg.lower():
                # Stored cookies most likely expired - drop the session so the
                # frontend prompts sign-in again instead of looping on errors.
                self.clear_session()
                raise AuthError("Session expired or invalid. Please sign in again.") from e
            raise


# Single shared instance used by the FastAPI app.
ytmusic_service = YtmusicService()
