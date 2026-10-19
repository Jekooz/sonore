"""
Browser-based sign-in orchestration.

No browser extension is involved. One attempt does, in order:

1. **Zero-click** — read an already signed-in Firefox profile straight from
   disk (``browser_cookies.cookies_from_firefox``). Nothing opens; a returning
   Firefox user is simply signed in.
2. **A window to sign in** — start the Edge/Chrome that ships with the machine
   in a profile this app owns, pointed at music.youtube.com, and read the
   session over the DevTools protocol once the user has signed in
   (``browser_cookies.launch_controllable_browser`` / ``read_devtools_cookies``).
   This is a normal browser window: Google sees nothing to object to, and there
   is no extension to load.
3. **Hand-off** — the Settings "paste request headers" fallback delivers a jar
   to this attempt directly (``deliver``).

A validated jar is stored through the same encrypted path as every other
source; this module never sees storage or HTTP details, only the callbacks it
was handed.

State machine (exposed via /auth/browser/status):
  idle -> waiting -> success | timeout | failed | cancelled
Never log cookie names or values from here; main.py logs only counts.
"""

import logging
import threading
import time
import webbrowser
import winreg

from services.browser_cookies import (
    BrowserLaunchError,
    browser_profile_dir,
    cookies_from_firefox,
    find_controllable_browser,
    launch_controllable_browser,
    read_devtools_cookies,
)

logger = logging.getLogger("ytmusic-backend")

MUSIC_URL = "https://music.youtube.com"

POLL_INTERVAL_SECONDS = 2.0
WAIT_TIMEOUT_SECONDS = 180.0  # 3 minutes, per spec

# Cookies that must be present before a captured jar is worth verifying. Kept in
# step with ytmusic_client.REQUIRED_COOKIES; duplicated here so this module
# stays free of any dependency on the storage layer.
_REQUIRED_COOKIES = ("__Secure-3PAPISID", "SAPISID", "SID")

# Registry UserChoice ProgId -> friendly browser name. Anything unrecognized is
# still opened through the OS shell; unknown only means "no friendly name".
_PROGID_MAP = {
    "CHROMEHTML": "Chrome",
    "MSEEDGEHTM": "Edge",
    "FIREFOXURL-3080465078": "Firefox",
    "FIREFOXURL": "Firefox",
    "BRAVEHTML": "Brave",
    "OPERHTML": "Opera",
    "OPERAHTM": "Opera",
    "VIVALDIHTM": "Vivaldi",
    "COMETHTM": "Comet (Perplexity)",
}


def detect_default_browser() -> str:
    """Friendly name of the default HTTPS browser, or "default browser".

    Read from HKCU UrlAssociations (the settings the user actually controls),
    never from a hard-coded path or a specific vendor key.
    """
    try:
        with winreg.OpenKey(
            winreg.HKEY_CURRENT_USER,
            r"Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice",
        ) as key:
            progid, _ = winreg.QueryValueEx(key, "ProgId")
        progid_upper = (progid or "").upper()
        for known, name in _PROGID_MAP.items():
            if progid_upper.startswith(known.upper()):
                return name
        return "default browser"
    except OSError:
        return "default browser"


class BrowserAuthSession:
    """One sign-in attempt: capture a session, from the easiest source first."""

    def __init__(self, completer=None, direct_reader=None):
        # completer: callable(cookies, source) -> None. Validates the candidate
        # against YouTube and stores it encrypted; raises when it is refused.
        # Keeps this module free of storage/HTTP knowledge.
        # direct_reader: callable() -> dict | None. A zero-click jar from an
        # already signed-in browser; None is "no such session", not an error.
        self._completer = completer
        self._direct_reader = direct_reader
        self._lock = threading.Lock()
        self._state = "waiting"
        self._error = None
        self._wake = threading.Event()
        self._thread = None
        self._devtools_port = 0
        self._open_browser = True
        self._browser = detect_default_browser()
        # The hand-off slot for THIS attempt, per-session on purpose: a shared
        # module-level slot let a superseded attempt's poll loop consume the jar
        # meant for the live one, leaving the app waiting forever on a retry.
        self._jar = None
        self._jar_event = threading.Event()

    def deliver(self, cookies: dict) -> bool:
        """Hand a validated cookie jar to this attempt.

        Returns False when the attempt is no longer waiting (cancelled, failed
        or already completed), so a late hand-off cannot resurrect it.
        """
        with self._lock:
            if self._state != "waiting":
                return False
            self._jar = cookies
        self._jar_event.set()
        return True

    def _take_jar(self) -> dict | None:
        """Consume the jar delivered to this attempt, if one is pending."""
        if self._jar_event.wait(0.1):
            self._jar_event.clear()
            jar, self._jar = self._jar, None
            return jar
        return None

    # ---------------- lifecycle ----------------

    def start(self, open_browser: bool = True):
        """Begin the attempt.

        [open_browser] is False for the paste-headers fallback, which supplies
        the session itself and must not have a window opened for it.
        """
        self._open_browser = open_browser
        if open_browser:
            found = find_controllable_browser()
            if found is not None:
                with self._lock:
                    self._browser = found[0]
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def cancel(self):
        with self._lock:
            if self._state == "waiting":
                self._state = "cancelled"
        self._wake.set()

    def complete_with_cookies(self, source_name):
        """Cookie hand-off arrived (main.py validates + stores, then calls this)."""
        with self._lock:
            self._state = "success"
        logger.info("browser auth: success via %s", source_name)

    def fail(self, error):
        with self._lock:
            self._state = "failed"
            self._error = error
        self._wake.set()

    def status(self):
        with self._lock:
            return {
                "state": self._state,
                "browser": self._browser,
                "error": self._error,
            }

    # ---------------- the attempt ----------------

    def _is_waiting(self) -> bool:
        with self._lock:
            return self._state == "waiting"

    def _run(self):
        # 1. Zero-click: a browser already holding a session. A refusal here is
        #    not fatal — it just means the user has to sign in in the window.
        if self._direct_reader is not None and self._is_waiting():
            try:
                jar = self._direct_reader()
            except Exception as e:  # noqa: BLE001 - any read failure is "no jar"
                logger.warning("browser auth: direct cookie read failed (%s)", e)
                jar = None
            if jar and all(jar.get(name) for name in _REQUIRED_COOKIES):
                if self._complete(jar, "installed browser", fatal=False):
                    return

        # 2. A window to sign in.
        if self._open_browser:
            if not self._start_browser():
                return

        # 3. Wait for the session to appear.
        self._poll_loop()

    def _start_browser(self) -> bool:
        found = find_controllable_browser()
        if found is None:
            # No controllable browser: open the default browser through the OS
            # shell so the user can still copy request headers into Settings.
            try:
                webbrowser.open_new_tab(MUSIC_URL)
                logger.info(
                    "browser auth: %s opened through the OS shell (no controllable browser)",
                    MUSIC_URL,
                )
            except Exception as e:  # noqa: BLE001
                self.fail(f"Could not open a browser: {e}")
                return False
            return True

        try:
            port = launch_controllable_browser(MUSIC_URL, browser_profile_dir())
        except BrowserLaunchError as e:
            logger.error("browser auth: %s", e)
            self.fail(str(e))
            return False
        with self._lock:
            self._devtools_port = port
        return True

    def _poll_loop(self):
        deadline = time.monotonic() + WAIT_TIMEOUT_SECONDS
        while time.monotonic() < deadline:
            # A jar handed over by main.py (the paste fallback). It was already
            # validated and stored before it was delivered.
            cookies = self._take_jar()
            if cookies:
                self.complete_with_cookies("hand-off")
                return

            # A session in the window this app opened.
            if self._devtools_port:
                try:
                    jar = read_devtools_cookies(
                        self._devtools_port,
                        deadline=time.monotonic() + POLL_INTERVAL_SECONDS,
                    )
                except Exception as e:  # noqa: BLE001 - the window may not be ready
                    logger.debug("browser auth: DevTools read skipped (%s)", e)
                    jar = None
                if jar and all(jar.get(name) for name in _REQUIRED_COOKIES):
                    # Once the required cookies are there the user HAS signed
                    # in, so a refusal is a real failure, not a transient one.
                    self._complete(jar, "sign-in window", fatal=True)
                    return

            if self._wake.wait(POLL_INTERVAL_SECONDS):
                return  # cancelled or failed

        self.fail(
            f"Timed out after {int(WAIT_TIMEOUT_SECONDS / 60)} minutes waiting for "
            f"sign-in in {self._browser}"
        )

    def _complete(self, jar: dict, source: str, fatal: bool) -> bool:
        """Validate + store a captured jar; True when the attempt is finished."""
        if self._completer is None:
            self.complete_with_cookies(source)
            return True
        try:
            self._completer(jar, source)
        except Exception as e:  # noqa: BLE001 - HTTPException carries .detail
            message = getattr(e, "detail", None) or str(e) or "Sign-in failed."
            logger.error("browser auth: the %s session was refused", source)
            if fatal:
                self.fail(message)
            return False
        self.complete_with_cookies(source)
        return True
