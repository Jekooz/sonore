"""
Browser-based sign-in orchestration.

No browser extension is involved. One attempt does, in order:

1. **Zero-click** — read an already signed-in Firefox profile straight from
   disk (``browser_cookies.cookies_from_firefox``). Nothing opens; a returning
   Firefox user is simply signed in.
2. **A window to sign in** — start the browser the user actually chose in
   Windows in a profile this app owns, pointed at music.youtube.com, and read
   the session over the DevTools protocol once the user has signed in
   (``browser_cookies.launch_controllable_browser`` / ``read_devtools_cookies``).
   If their default is Firefox, the same window is their own Firefox and the
   poll loop reads the profile instead — Firefox cannot be driven, and does not
   need to be. Edge or Chrome is driven only when nothing else can be. This is
   a normal browser window: Google sees nothing to object to, and there is no
   extension to load.
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

from services.browser_cookies import (
    BrowserLaunchError,
    browser_profile_dir,
    cookies_from_firefox,
    launch_controllable_browser,
    read_devtools_cookies,
    sign_in_plan,
)

logger = logging.getLogger("ytmusic-backend")

MUSIC_URL = "https://music.youtube.com"

POLL_INTERVAL_SECONDS = 2.0
WAIT_TIMEOUT_SECONDS = 180.0  # 3 minutes, per spec

# Cookies that must be present before a captured jar is worth verifying. Kept in
# step with ytmusic_client.REQUIRED_COOKIES; duplicated here so this module
# stays free of any dependency on the storage layer.
_REQUIRED_COOKIES = ("__Secure-3PAPISID", "SAPISID", "SID")


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
        # Replaced by sign_in_plan() the moment an attempt opens a browser, so
        # the prompt the user reads and the window that opens cannot disagree.
        # The paste-headers flow never opens one and never resolves this.
        self._browser = "your browser"
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
            with self._lock:
                self._browser = sign_in_plan()[1]
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

    def _read_directly(self, first=False):
        """A zero-click jar from the user's own browser profile, if any.

        [first] is the read made before anything opens, where a failure is worth
        a warning; the poll loop repeats it every couple of seconds, where a
        failure is only ever noise.
        """
        try:
            return self._direct_reader()
        except Exception as e:  # noqa: BLE001 - any read failure is "no jar"
            logger.log(
                logging.WARNING if first else logging.DEBUG,
                "browser auth: direct cookie read failed (%s)",
                e,
            )
            return None

    def _is_waiting(self) -> bool:
        with self._lock:
            return self._state == "waiting"

    def _run(self):
        # 1. Zero-click: a browser already holding a session. A refusal here is
        #    not fatal — it just means the user has to sign in in the window.
        if self._direct_reader is not None and self._is_waiting():
            jar = self._read_directly(first=True)
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
        mode, browser = sign_in_plan()
        with self._lock:
            self._browser = browser

        if mode == "firefox":
            # Their default is Firefox, which cannot be driven over DevTools and
            # does not need to be: its cookies are a plain SQLite file. Open the
            # URL in the profile they already use and the poll loop reads the
            # session out of it.
            return self._open_in_default_browser()

        if mode == "devtools":
            try:
                name, port = launch_controllable_browser(
                    MUSIC_URL, browser_profile_dir()
                )
            except BrowserLaunchError as e:
                logger.error("browser auth: %s", e)
                self.fail(str(e))
                return False
            with self._lock:
                self._browser = name
                self._devtools_port = port
            return True

        # Nothing on this machine can be driven, so an attempt could only ever
        # time out. Say what to do instead of waiting three minutes for it.
        self.fail(
            "Sign-in could not open a browser window it can read. You can sign "
            "in to YouTube Music in your own browser and paste the request "
            "headers in Settings, under Account."
        )
        return False

    def _open_in_default_browser(self) -> bool:
        """Open the sign-in page through the OS shell.

        The shell is what applies the user's own default-browser setting, so
        this needs no knowledge of which browser that is.
        """
        try:
            if webbrowser.open_new_tab(MUSIC_URL):
                logger.info("browser auth: %s opened in the default browser", MUSIC_URL)
                return True
            self.fail("Could not open your browser to sign in.")
        except Exception as e:  # noqa: BLE001
            self.fail(f"Could not open your browser to sign in: {e}")
        return False

    def _poll_loop(self):
        deadline = time.monotonic() + WAIT_TIMEOUT_SECONDS
        while time.monotonic() < deadline:
            # A jar handed over by main.py (the paste fallback). It was already
            # validated and stored before it was delivered.
            cookies = self._take_jar()
            if cookies:
                self.complete_with_cookies("hand-off")
                return

            # A session in the window this app opened, or in the user's own
            # Firefox when that is the browser sign-in is using.
            if self._devtools_port:
                try:
                    jar = read_devtools_cookies(
                        self._devtools_port,
                        deadline=time.monotonic() + POLL_INTERVAL_SECONDS,
                    )
                except Exception as e:  # noqa: BLE001 - the window may not be ready
                    logger.debug("browser auth: DevTools read skipped (%s)", e)
                    jar = None
            elif self._direct_reader is not None:
                jar = self._read_directly()
            else:
                jar = None

            if jar and all(jar.get(name) for name in _REQUIRED_COOKIES):
                # Once the required cookies are there the user HAS signed in,
                # so a refusal is a real failure, not a transient one.
                source = "sign-in window" if self._devtools_port else "browser profile"
                self._complete(jar, source, fatal=True)
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
