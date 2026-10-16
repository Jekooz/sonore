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
     exactly like music.youtube.com does in a normal browser) and stores it encrypted
     via Windows DPAPI (CryptProtectData) in a file under %LOCALAPPDATA%. Cookies are
     never written to disk in plaintext; the DPAPI blob is encrypted with the user's
     Windows logon credentials and is only readable by the same user account.

This is the same auth mechanism as `ytmusicapi`'s browser setup, automated.
Verified against ytmusicapi 1.12.3 source:
  - ytmusicapi/ytmusic.py:  AuthType.BROWSER requires base_headers["cookie"] and
    recomputes headers["authorization"] = get_authorization(sapisid + " " + origin)
    on each request (SAPISIDHASH <ts>_<sha1(ts + " " + sapisid + " " + origin)>).
  - ytmusicapi/helpers.py:  sapisid_from_cookie() reads the __Secure-3PAPISID cookie.
  - ytmusicapi/auth/auth_parse.py: a dict containing "cookie" + "authorization"
    (SAPISIDHASH) is treated as BROWSER auth; no OAuthCredentials needed.
"""

import ctypes
import ctypes.wintypes as wintypes
import json
import logging
import os
import re
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
    """Raised when credential storage (keyring or DPAPI) is unavailable or refuses writes."""


# ---- DPAPI-based encrypted file storage (overcomes Credential Manager 512-byte limit) ----
#
# Windows Credential Manager (used by the ``keyring`` library's WinVaultKeyring) caps the
# credential blob at 512 bytes.  Our auth headers JSON — which includes the full Cookie
# header with ~15 Google cookies — easily exceeds that, causing CredWrite error 1783
# (ERROR_INVALID_DATA).  Instead we use CryptProtectData / CryptUnprotectData from dpapi
# via ctypes: the data is encrypted with the user's logon credentials (DPAPI) and written
# to a file under %LOCALAPPDATA%.  This is secure, has no size limit, and needs no extra
# packages (ctypes is in the standard library).

# True only on Windows where dpapi.dll / crypt32.dll are available.
_DPAPI_AVAILABLE = hasattr(ctypes, "windll")

# File path for the encrypted auth headers blob.
_APP_DATA_DIR = os.path.join(
    os.environ.get("LOCALAPPDATA", os.path.join(os.path.expanduser("~"), "AppData", "Local")),
    "ytmusic_client",
)
_AUTH_FILE = os.path.join(_APP_DATA_DIR, "auth_headers.dat")


class _DATA_BLOB(ctypes.Structure):
    _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(wintypes.BYTE))]


def _dpapi_encrypt(data: bytes) -> bytes:
    """Encrypt *data* with Windows DPAPI (CryptProtectData).

    The returned bytes are opaque and can be written verbatim to a file.
    Raises ``StorageError`` on failure.
    """
    blob_in = _DATA_BLOB()
    blob_out = _DATA_BLOB()

    # create_string_buffer allocates a writable buffer initialised with *data*
    # (no need for LocalAlloc/memmove which caused access violations).
    buf = ctypes.create_string_buffer(data)
    blob_in.cbData = len(data)
    blob_in.pbData = ctypes.cast(buf, ctypes.POINTER(wintypes.BYTE))

    success = ctypes.windll.crypt32.CryptProtectData(
        ctypes.byref(blob_in),
        "ytmusic_client auth headers",
        None, None, None, 0,
        ctypes.byref(blob_out),
    )
    result = ctypes.string_at(blob_out.pbData, blob_out.cbData) if blob_out.cbData else b""
    ctypes.windll.kernel32.LocalFree(blob_out.pbData)

    if not success:
        raise StorageError(f"DPAPI encryption failed (error {ctypes.GetLastError()})")
    return result


def _dpapi_decrypt(data: bytes) -> bytes:
    """Decrypt *data* previously produced by :func:`_dpapi_encrypt`."""
    blob_in = _DATA_BLOB()
    blob_out = _DATA_BLOB()

    buf = ctypes.create_string_buffer(data)
    blob_in.cbData = len(data)
    blob_in.pbData = ctypes.cast(buf, ctypes.POINTER(wintypes.BYTE))

    success = ctypes.windll.crypt32.CryptUnprotectData(
        ctypes.byref(blob_in), None, None, None, None, 0,
        ctypes.byref(blob_out),
    )
    result = ctypes.string_at(blob_out.pbData, blob_out.cbData) if blob_out.cbData else b""
    ctypes.windll.kernel32.LocalFree(blob_out.pbData)

    if not success:
        raise StorageError(f"DPAPI decryption failed (error {ctypes.GetLastError()})")
    return result


def _build_cookie_header(cookie_map: dict) -> str:
    """
    Serialize exactly the cookies ytmusicapi needs into a Cookie header value.

    Only REQUIRED + USEFUL cookie names are forwarded. Search.eye results used to
    "append every other cookie that arrived" — 24 Google cookies, far beyond what
    the 2560-byte Credential Manager blob (pre-DPAPI) or the settings flow needs,
    and needlessly exposing session material to disk. Keep the jar small.
    """
    parts = []
    for name in dict.fromkeys(REQUIRED_COOKIES + USEFUL_COOKIES):
        value = cookie_map.get(name)
        if value:
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


# Labels YouTube Music uses for its own navigation rather than for a person.
#
# Measured on a real signed-in session (2026-10-15): `get_account_info()`
# answered `accountName: "Home"` while `channelHandle` from the same response
# was the real `@handle`. The account menu's name run is whatever the service
# put there, so a name that is one of these labels is not a name and is dropped
# rather than shown to the user.
_CHROME_LABELS = frozenset({
    "home",
    "explore",
    "library",
    "search",
    "settings",
    "now playing",
    "new",
    "downloads",
    "albums",
    "artists",
    "songs",
    "playlists",
    "liked music",
    "music",
    "youtube music",
    "menu",
    "sign in",
    "your account",
})


def sanitize_account(info) -> dict:
    """Account info with a non-name dropped instead of displayed.

    Returns the three fields the app reads, always present. When the service's
    `accountName` is missing, empty or one of its own chrome labels, it becomes
    None so the client falls back to the real channel handle (or to a neutral
    label) instead of showing "Home" as the signed-in account.
    """
    if not isinstance(info, dict):
        return {"accountName": None, "channelHandle": None, "accountPhotoUrl": None}

    def text(value):
        if not isinstance(value, str):
            return None
        value = value.strip()
        return value or None

    name = text(info.get("accountName"))
    if name is not None and name.casefold() in _CHROME_LABELS:
        logger.info("Account name from the service is a chrome label; omitting it.")
        name = None

    return {
        "accountName": name,
        "channelHandle": text(info.get("channelHandle")),
        "accountPhotoUrl": text(info.get("accountPhotoUrl")),
    }


class YtmusicService:
    """
    Holds the sign-in session (headers encrypted via DPAPI, with keyring fallback)
    and provides YTMusic clients.

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

    # ---------- DPAPI file storage ----------

    @staticmethod
    def _dpapi_get() -> str | None:
        """Read and decrypt auth headers from the DPAPI-protected file."""
        if not _DPAPI_AVAILABLE:
            return None
        if not os.path.exists(_AUTH_FILE):
            return None
        try:
            with open(_AUTH_FILE, "rb") as f:
                encrypted = f.read()
            decrypted = _dpapi_decrypt(encrypted)
            return decrypted.decode("utf-8")
        except StorageError as e:
            # Could not decrypt — corrupt or wrong user.  Wipe it so we don't
            # keep erroring on every read.
            logger.warning("DPAPI decryption failed: %s — removing stale file.", e)
            try:
                os.remove(_AUTH_FILE)
            except OSError:
                pass
            return None
        except OSError as e:
            logger.warning("Could not read auth file: %s.", e)
            return None

    @staticmethod
    def _dpapi_set(value: str) -> None:
        """Encrypt *value* with DPAPI and write it to the auth file."""
        if not _DPAPI_AVAILABLE:
            raise StorageError("DPAPI not available on this platform")
        os.makedirs(_APP_DATA_DIR, exist_ok=True)
        encrypted = _dpapi_encrypt(value.encode("utf-8"))
        # Write atomically: write to temp file then rename.
        tmp_path = _AUTH_FILE + ".tmp"
        with open(tmp_path, "wb") as f:
            f.write(encrypted)
        os.replace(tmp_path, _AUTH_FILE)

    @staticmethod
    def _dpapi_delete() -> None:
        """Delete the encrypted auth file if it exists."""
        try:
            if os.path.exists(_AUTH_FILE):
                os.remove(_AUTH_FILE)
        except OSError as e:
            logger.warning("Could not remove auth file: %s.", e)

    # ---------- session methods ----------

    def verify_candidate(self, cookie_map: dict) -> dict:
        """Confirm YouTube accepts these cookies, WITHOUT touching stored ones.

        Sign-in must never damage a working session (M2): if a hand-off carries
        the wrong account, an expired jar or a partial set, the attempt has to
        fail while the previously stored headers stay exactly as they were. So
        verification is deliberately separate from store_session(), and it must
        NOT go through call()/clear_session() — that path drops the stored
        session on a 401/403, which is the behaviour being avoided here.

        Raises AuthError when required cookies are missing, or whatever the
        upstream call raised when YouTube rejects the candidate.
        """
        headers = build_auth_headers(cookie_map)
        candidate = YTMusic(auth=headers)
        # The account menu's name run is not always a name (see
        # _CHROME_LABELS), so the same sanitizing is applied on this path: the
        # sign-in response and the Settings screen must agree about who is
        # signed in.
        return sanitize_account(candidate.get_account_info())

    def store_session(self, cookie_map: dict) -> dict:
        """Validate cookies, store headers securely, reset the client.

        On Windows, uses DPAPI (CryptProtectData) to encrypt the headers and
        writes them to a file under %LOCALAPPDATA%.  This avoids the 512-byte
        Credential Manager limit that caused CredWrite error 1783.
        Falls back to keyring for backwards compatibility or non-Windows.
        """
        headers = build_auth_headers(cookie_map)
        value = json.dumps(headers)
        if _DPAPI_AVAILABLE:
            self._dpapi_set(value)
        else:
            self._keyring_set(value)
        with self._lock:
            self._client = None  # force rebuild on next use
        return {"signed_in": True}

    def get_headers(self) -> dict | None:
        # Prefer DPAPI file (primary storage on Windows).  Fall back to keyring
        # for sessions stored by an older version of this app.
        stored = self._dpapi_get()
        if stored is None:
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
        # Clear both storage backends (in case a session was stored by either).
        if _DPAPI_AVAILABLE:
            self._dpapi_delete()
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
                # Audit finding 6: never embed upstream exception text in an
                # AuthError — these strings are surfaced in HTTP details.
                raise AuthError(
                    "Could not initialize the YouTube Music client."
                ) from e
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
            # The substring "authentication" used to decide session expiry, which
            # also fired on network failures phrased with the same word. Classify
            # on the real HTTP status instead: ytmusicapi surfaces request errors
            # with a status attribute (or an "extracted <status>" message).
            status = getattr(e, "status", None)
            if status is None:
                m = re.search(r"\b(?:extracted|status)[: ]+(\d{3})\b", str(e))
                status = int(m.group(1)) if m else None
            if status in (401, 403):
                # Cookies most likely expired - drop the session so the frontend
                # prompts sign-in again instead of looping on errors.
                self.clear_session()
                raise AuthError("Session expired or invalid. Please sign in again.") from e
            # Any other failure (network, YouTube outage): keep the session.
            raise


# Single shared instance used by the FastAPI app.
ytmusic_service = YtmusicService()
