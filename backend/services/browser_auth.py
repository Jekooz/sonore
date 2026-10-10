"""
Browser-based sign-in orchestration.

Flow (replaces the WebView2 sign-in window):
  1. /auth/browser/start -> detect the default browser from the registry
     (HKCU\\Software\\Microsoft\\Windows\\Shell\\Associations\\UrlAssociations\\https\\UserChoice),
     open https://music.youtube.com in it via the OS shell (never a hard-coded
     browser), and flip the state machine to "waiting".
  2. The user signs in normally in their own browser.
  3. The paired browser extension reads the youtube.com cookies (chrome.cookies
     includes HttpOnly) and POSTs them to /auth/extension, which completes the
     exact same store+validate path as the old WebView2 capture.

Why the extension is the primary (and on this build, only) cookie source:
the direct-read library rookiepy has no Windows CPython 3.13 wheel (0.5.6
ships cp37-cp312 only; building it here needs an MSVC/Rust toolchain this
machine does not have), and Chromium's App-Bound Encryption also blocks plain
file reads on current Chrome/Edge/Brave. A signed-in browser can hand its own
cookies to a local extension, which no Windows policy blocks. The poller keeps
strategy A structured so a future wheelhop (rookiepy import guarded) lights up
automatically — see cookies_from_installed_rookiepy().

State machine (exposed via /auth/browser/status):
  idle -> waiting -> success | timeout | failed | cancelled
Never log cookie names or values from here; main.py logs only counts.
"""

import logging
import threading
import time
import webbrowser
import winreg

logger = logging.getLogger("ytmusic-backend")

MUSIC_URL = "https://music.youtube.com"

POLL_INTERVAL_SECONDS = 2.0
WAIT_TIMEOUT_SECONDS = 180.0  # 3 minutes, per spec

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
            r"Software\\Microsoft\\Windows\\Shell\\Associations\\UrlAssociations\\https\\UserChoice",
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
    """One sign-in attempt: open the browser, poll for the extension hand-off."""

    def __init__(self, cookie_source):
        # cookie_source: callable () -> dict | None, injected by main.py —
        # returns a youtube.com cookie jar when one has arrived, else None.
        # Injection keeps this module free of HTTP/server knowledge.
        self._cookie_source = cookie_source
        self._lock = threading.Lock()
        self._state = "waiting"
        self._error = None
        self._wake = threading.Event()
        self._thread = None

    # ---------------- lifecycle ----------------

    def start(self):
        browser = detect_default_browser()
        with self._lock:
            self._browser = browser
        try:
            # OS shell handles the association - never a hard-coded executable.
            webbrowser.open_new_tab(MUSIC_URL)
            logger.info("browser auth: opened %s in %s", MUSIC_URL, browser)
        except Exception as e:
            with self._lock:
                self._state = "failed"
                self._error = f"Could not open {browser}: {e}"
            return

        self._thread = threading.Thread(target=self._poll_loop, daemon=True)
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
                "browser": getattr(self, "_browser", "default browser"),
                "error": self._error,
            }

    # ---------------- poll loop ----------------

    def _poll_loop(self):
        deadline = time.monotonic() + WAIT_TIMEOUT_SECONDS
        while time.monotonic() < deadline:
            if self._cookie_source is not None:
                try:
                    cookies = self._cookie_source()
                except Exception as e:
                    logger.error("browser auth: cookie source failed: %s", e)
                    self.fail(f"Cookie capture failed: {e}")
                    return

                if cookies:
                    # main.py has already stored+validated these before wiring
                    # the source; reaching here means everything succeeded.
                    self.complete_with_cookies("extension")
                    return

            if self._wake.wait(POLL_INTERVAL_SECONDS):
                return  # cancelled or failed

        self.fail(
            f"Timed out after {int(WAIT_TIMEOUT_SECONDS / 60)} minutes waiting for sign-in in "
            + getattr(self, "_browser", "the browser")
        )


# --------------- strategy A (direct read), structured but inert on cp313 ---------------


def cookies_from_installed_rookiepy(domains):
    """
    Direct cookie read via rookiepy, guarded at call time.

    rookiepy ships CPython 3.10-3.12 Windows wheels only (verified in the PyPI
    index for 0.5.6); on this 3.13 box the import fails and strategy B (the
    extension) takes over. Kept as a real implementation, not a stub, so the
    moment a cp313/abi3 wheel is installed the direct path works: NO fallback
    cookies are ever synthesized here — None means "no direct access".
    """
    try:
        import rookiepy  # noqa: F401  (availability IS the feature test)
    except ImportError:
        logger.info(
            "browser auth: rookiepy unavailable (no cp313 wheel) -> extension hand-off"
        )
        return None

    jars = []
    if "chrome" in dir(rookiepy):
        jars.append(rookiepy.chrome(domains))
    if "firefox" in dir(rookiepy):
        jars.append(rookiepy.firefox(domains))
    return {c["name"]: c["value"] for jar in jars for c in jar if c.get("name") and c.get("value")}
