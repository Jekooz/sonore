"""
Automated coverage for browser sign-in capture.

These tests drive the REAL FastAPI app through TestClient — the same routes the
desktop app calls — so the capture lifecycle is exercised through the production
code path, not a reimplementation.

Safety, enforced before anything else:

* Your real stored session (%LOCALAPPDATA%\\ytmusic_client\\auth_headers.dat) is
  never used as a fixture. ``_AUTH_FILE`` is redirected to a tmp dir for every
  test and a guard asserts the redirect happened.
* No browser opens and no browser profile is read: ``webbrowser`` is stubbed,
  no readable browser is reported, the sign-in profile lives in a tmp dir and
  the zero-click reader is replaced, so a test can never launch Edge or read
  the machine's own browser cookies.
* Only the success paths stub the network (verify_candidate) and disk
  (store_session); every rejection test runs against the real, unpatched code —
  that is exactly what it is checking.
"""

import logging
import os
import sys
import threading
import time
import types

import pytest
from fastapi.testclient import TestClient

BACKEND_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "backend"
)
if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)

import main  # noqa: E402  (needs BACKEND_DIR on sys.path first)
from services import browser_auth, browser_cookies  # noqa: E402
import services.ytmusic_client as ytc  # noqa: E402

TEST_PORT = 8123
COOKIE_VALUE_MARKER = "cookie-value-that-must-never-be-logged"

# A jar that passes the REQUIRED_COOKIES gate, so tests reach the storage logic
# rather than stopping at the "incomplete sign-in" check.
GOOD_JAR = {
    "__Secure-3PAPISID": COOKIE_VALUE_MARKER,
    "SAPISID": COOKIE_VALUE_MARKER,
    "SID": COOKIE_VALUE_MARKER,
    "HSID": "hsid",
}

REAL_SESSION_FILE = os.path.join(
    os.environ.get("LOCALAPPDATA", ""), "ytmusic_client", "auth_headers.dat"
)


@pytest.fixture(autouse=True)
def isolated_env(tmp_path, monkeypatch):
    """Redirect every piece of persistent state away from the real machine."""
    sandbox = tmp_path / "appdata"
    sandbox.mkdir()
    monkeypatch.setattr(ytc, "_APP_DATA_DIR", str(sandbox))
    monkeypatch.setattr(ytc, "_AUTH_FILE", str(sandbox / "auth_headers.dat"))

    # Per-install state (the API token, the update banner) lives in
    # %LOCALAPPDATA%\Sonore. Keep it out of the real machine's copy and never
    # let a test read or write the token the running app is using.
    sonore = tmp_path / "sonore"
    sonore.mkdir()
    monkeypatch.setattr(ytc, "_SONORE_DIR", str(sonore))
    monkeypatch.setattr(
        main, "_YT_DLP_DIR", str(sonore / "bin"), raising=False
    )
    monkeypatch.setattr(
        main, "_UPDATE_STATE_FILE", str(sonore / "update_state.json"), raising=False
    )
    monkeypatch.setattr(
        main, "PORT_FILE", str(sonore / "sidecar_port.txt"), raising=False
    )
    monkeypatch.setattr(main, "_install_token", None, raising=False)
    monkeypatch.setattr(main, "_updating", False, raising=False)

    # Guard: if this ever regresses, the tests would be writing to the real
    # credential file. Fail loudly instead.
    assert ytc._AUTH_FILE != REAL_SESSION_FILE
    assert "ytmusic_client" not in ytc._AUTH_FILE

    # Sign-in must never launch a browser or read the machine's own cookies.
    # Pin the decision itself, so a test never depends on this machine's own
    # default browser: an ordinary readable browser that produces no session.
    monkeypatch.setattr(
        browser_auth, "sign_in_plan", lambda: ("profile", "Microsoft Edge")
    )
    monkeypatch.setattr(
        browser_auth, "webbrowser",
        types.SimpleNamespace(open_new_tab=lambda url: True),
    )
    monkeypatch.setattr(
        browser_auth, "launch_readable_browser",
        lambda url, profile: ("Microsoft Edge", str(profile), FakeProcess(live=True)),
    )
    monkeypatch.setattr(
        browser_auth, "read_profile_cookies", lambda profile: None, raising=False,
    )
    monkeypatch.setattr(
        browser_auth, "close_browser_window", lambda process: None, raising=False,
    )
    monkeypatch.setattr(
        browser_auth, "browser_profile_dir", lambda: str(sonore / "sign-in-browser"),
        raising=False,
    )
    monkeypatch.setattr(main, "cookies_from_disk", lambda: None)

    main._clear_browser_session()

    yield

    main._clear_browser_session()
    main._install_token = None


@pytest.fixture
def client():
    # Loopback base_url on purpose: the install-token endpoint (and every
    # hand-off route) refuses a Host that is not 127.0.0.1/localhost, and
    # TestClient's default "testserver" name is exactly what must be refused.
    return TestClient(main.app, base_url=f"http://127.0.0.1:{TEST_PORT}")


@pytest.fixture
def api_token(client):
    """The per-install token, bootstrapped the way the app bootstraps it."""
    resp = client.get("/auth/install-token")
    assert resp.status_code == 200, resp.text
    return resp.json()["install_token"]


def start_sign_in(client, payload=None):
    """Begin a real sign-in attempt; returns the response body."""
    resp = client.post("/auth/browser/start", json=payload or {})
    assert resp.status_code == 200, resp.text
    return resp.json()


def wait_for_session_to_settle(client, seconds=6.0):
    """Poll the real status endpoint the way the desktop app does."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        state = client.get("/auth/browser/status").json()
        if state["state"] != "waiting":
            return state
        time.sleep(0.1)
    raise AssertionError("the sign-in attempt never left the waiting state")


def stub_storage(monkeypatch, verify=None, store=None):
    """Replace the network and disk steps, recording what they were given."""
    calls = {"stored": []}
    monkeypatch.setattr(
        main.ytmusic_service, "verify_candidate",
        verify or (lambda c, h=None: {"accountName": "x"}),
    )

    def default_store(cookies, headers=None):
        calls["stored"].append(cookies)
        return {"signed_in": True}

    monkeypatch.setattr(
        main.ytmusic_service, "store_session", store or default_store
    )
    return calls


class FakeProcess:
    """A sign-in window: open while the user is signing in, then gone."""

    def __init__(self, live=False, pid=4242):
        self.pid = pid
        self.live = live

    def poll(self):
        return None if self.live else 0


def use_readable_browser(monkeypatch, cookies=None, name="Microsoft Edge",
                         live=None, jar_readable=True, process=None):
    """Make the capture path behave as if a sign-in window produced a session.

    [live] defaults to "the window is still open when there is nothing to
    read", which is the real state while the user is signing in: a Chromium
    window's cookie store cannot be read until it has closed. [process] hands in
    a window of the caller's own, for tests that drive it themselves.
    """
    monkeypatch.setattr(browser_auth, "sign_in_plan", lambda: ("profile", name))
    if live is None:
        live = cookies is None
    if process is None:
        process = FakeProcess(live=live)
    launched = []
    reads = []

    def launch(url, profile):
        launched.append((url, profile))
        return name, str(profile), process

    def read(profile):
        reads.append(profile)
        if not jar_readable:
            return None
        # A readable store with no session is {}, which is not the same answer
        # as one that could not be read at all.
        return cookies if cookies is not None else {}

    monkeypatch.setattr(browser_auth, "launch_readable_browser", launch)
    monkeypatch.setattr(browser_auth, "read_profile_cookies", read)
    return launched


# ------------------------------------------------------------ start / shape


def test_start_reports_a_waiting_attempt_with_no_pairing_token(client):
    body = start_sign_in(client)
    assert body["state"] == "waiting"
    assert "token" not in body, "the pairing token is gone with the extension"
    assert body.get("error") is None


def test_browser_info_names_the_browser_sign_in_will_use(client, monkeypatch):
    monkeypatch.setattr(main, "planned_browser_name", lambda: "Comet")
    resp = client.get("/auth/browser/info")
    assert resp.status_code == 200, resp.text
    assert resp.json()["browser"] == "Comet"


def test_start_opens_a_window_in_a_profile_the_app_owns(client, monkeypatch):
    launched = use_readable_browser(monkeypatch, cookies=None)
    start_sign_in(client)

    deadline = time.monotonic() + 5
    while not launched and time.monotonic() < deadline:
        time.sleep(0.05)
    assert len(launched) == 1, "a real sign-in must open exactly one window"
    url, profile = launched[0]
    assert url == browser_auth.MUSIC_URL
    assert "sign-in-browser" in profile


def test_the_users_default_browser_is_the_one_opened(client, monkeypatch):
    """Their setting decides, not a vendor preference: Comet here, not Edge."""
    launched = use_readable_browser(
        monkeypatch, cookies=None, name="Comet"
    )
    start_sign_in(client)

    deadline = time.monotonic() + 5
    while not launched and time.monotonic() < deadline:
        time.sleep(0.05)
    assert len(launched) == 1
    assert client.get("/auth/browser/status").json()["browser"] == "Comet"


def test_firefox_default_opens_their_own_browser_and_reads_it(client, monkeypatch):
    """Firefox cannot be driven, and does not need to be: read its profile."""
    opened = []
    monkeypatch.setattr(
        browser_auth, "sign_in_plan", lambda: ("firefox", "Mozilla Firefox")
    )
    monkeypatch.setattr(
        browser_auth, "webbrowser",
        types.SimpleNamespace(open_new_tab=lambda url: opened.append(url) or True),
    )
    monkeypatch.setattr(
        browser_auth, "launch_readable_browser",
        lambda url, profile: (_ for _ in ()).throw(
            AssertionError("a Firefox sign-in must not launch a second browser")
        ),
    )

    reads = {"count": 0}

    def firefox_once_signed_in():
        reads["count"] += 1
        # Nothing yet on the pre-window read; a session appears while the user
        # is signing in, which is what the poll loop is for.
        return None if reads["count"] == 1 else dict(GOOD_JAR)

    monkeypatch.setattr(main, "cookies_from_disk", firefox_once_signed_in)
    calls = stub_storage(monkeypatch)

    start_sign_in(client)
    state = wait_for_session_to_settle(client)

    assert opened == [browser_auth.MUSIC_URL], "their own Firefox is opened"
    assert state["state"] == "success", state
    assert calls["stored"] == [dict(GOOD_JAR)]


def test_a_browser_that_will_not_start_says_so(client, monkeypatch):
    """A refused launch must surface, not leave the screen waiting."""
    def refuse(url, profile):
        raise browser_cookies.BrowserLaunchError(
            "Comet: it did not finish starting in time"
        )

    monkeypatch.setattr(browser_auth, "launch_readable_browser", refuse)
    start_sign_in(client)

    state = wait_for_session_to_settle(client)
    assert state["state"] == "failed", state
    assert "did not finish starting" in (state["error"] or "")


def test_nothing_drivable_fails_with_the_paste_fallback(client, monkeypatch):
    """No browser the app can read: fail with something to do, not a wait."""
    monkeypatch.setattr(
        browser_auth, "sign_in_plan", lambda: ("shell", "Some Browser")
    )
    monkeypatch.setattr(
        browser_auth, "launch_readable_browser",
        lambda url, profile: (_ for _ in ()).throw(
            AssertionError("nothing readable means nothing to launch")
        ),
    )

    start_sign_in(client)

    state = wait_for_session_to_settle(client)
    assert state["state"] == "failed", state
    assert "Settings" in (state["error"] or ""), state["error"]


def test_open_browser_false_neither_reads_nor_launches(client, monkeypatch):
    """The paste-headers fallback supplies the session itself."""
    def explode():
        raise AssertionError("the paste flow must not read a browser")

    monkeypatch.setattr(main, "cookies_from_disk", explode)
    monkeypatch.setattr(
        browser_auth, "sign_in_plan",
        lambda: (_ for _ in ()).throw(
            AssertionError("the paste flow must not pick a browser")
        ),
    )
    monkeypatch.setattr(
        browser_auth, "launch_readable_browser",
        lambda url, profile: (_ for _ in ()).throw(
            AssertionError("the paste flow must not launch a browser")
        ),
    )

    body = start_sign_in(client, {"open_browser": False})
    assert body["state"] == "waiting"
    time.sleep(0.3)
    assert client.get("/auth/browser/status").json()["state"] == "waiting"


def test_the_removed_extension_endpoints_are_gone(client):
    assert client.post("/auth/extension", json={"cookies": {}}).status_code == 404
    assert client.get("/auth/extension/folder").status_code == 404


# ------------------------------------------------------------ zero-click read


def test_zero_click_firefox_session_signs_in_with_no_window(client, monkeypatch):
    """An already signed-in Firefox means no window and no click at all."""
    monkeypatch.setattr(main, "cookies_from_disk", lambda: dict(GOOD_JAR))
    monkeypatch.setattr(
        browser_auth, "launch_readable_browser",
        lambda url, profile: (_ for _ in ()).throw(
            AssertionError("a zero-click session must not open a window")
        ),
    )
    calls = stub_storage(monkeypatch)

    start_sign_in(client)

    state = wait_for_session_to_settle(client)
    assert state["state"] == "success", state
    assert calls["stored"] == [dict(GOOD_JAR)]


def test_zero_click_jar_without_a_session_is_not_accepted(client, monkeypatch):
    """Anonymous cookies (YSC, VISITOR_INFO1_LIVE, ...) are not a session."""
    monkeypatch.setattr(
        main, "cookies_from_disk",
        lambda: {"YSC": "x", "VISITOR_INFO1_LIVE": "y"},
    )
    calls = stub_storage(monkeypatch)

    start_sign_in(client)
    time.sleep(0.3)

    assert calls["stored"] == [], "an anonymous jar must never be stored"
    # And it must fall through to the window rather than failing.
    assert client.get("/auth/browser/status").json()["state"] == "waiting"


def test_zero_click_refusal_falls_through_to_the_window(client, monkeypatch):
    """A stale Firefox session is not fatal: the user can sign in again."""
    monkeypatch.setattr(main, "cookies_from_disk", lambda: dict(GOOD_JAR))
    use_readable_browser(monkeypatch, cookies=None)

    def reject(_cookies):
        raise RuntimeError("401 from upstream")

    stub_storage(monkeypatch, verify=reject)

    start_sign_in(client)
    time.sleep(0.4)
    assert client.get("/auth/browser/status").json()["state"] == "waiting"


# ------------------------------------------------------------ captured window


def test_a_window_closed_without_a_session_fails_with_a_reason(client, monkeypatch):
    """Nothing can change once the window is gone, so waiting would be wrong."""
    use_readable_browser(monkeypatch, cookies=None, live=False)

    start_sign_in(client)

    state = wait_for_session_to_settle(client)
    assert state["state"] == "failed", state
    assert "closed before you signed in" in (state["error"] or "").lower()


def test_a_window_another_process_still_holds_keeps_waiting(client, monkeypatch):
    """A locked store is not an empty one: another window may still sign in."""
    use_readable_browser(monkeypatch, cookies=None, live=False, jar_readable=False)

    start_sign_in(client)
    time.sleep(0.4)

    assert client.get("/auth/browser/status").json()["state"] == "waiting"


def test_session_from_the_window_signs_in(client, monkeypatch):
    use_readable_browser(monkeypatch, cookies=dict(GOOD_JAR))
    calls = stub_storage(monkeypatch)

    start_sign_in(client)

    state = wait_for_session_to_settle(client)
    assert state["state"] == "success", state
    assert calls["stored"] == [dict(GOOD_JAR)]


def test_window_session_refused_by_youtube_fails_the_attempt(client, monkeypatch):
    """The required cookies are present, so this is a real refusal, not a retry."""
    use_readable_browser(monkeypatch, cookies=dict(GOOD_JAR))

    def reject(_cookies):
        raise main.AuthError("Session expired or invalid. Please sign in again.")

    calls = stub_storage(monkeypatch, verify=reject)

    start_sign_in(client)

    state = wait_for_session_to_settle(client)
    assert state["state"] == "failed", state
    assert "sign in again" in (state["error"] or "").lower()
    assert calls["stored"] == [], "a refused candidate must never reach storage"


def test_a_window_left_open_is_closed_and_read_at_the_timeout(client, monkeypatch):
    """Signing in and walking away still ends signed in, not stuck waiting."""
    monkeypatch.setattr(browser_auth, "WAIT_TIMEOUT_SECONDS", 3.0)
    monkeypatch.setattr(browser_auth, "CLOSE_GRACE_SECONDS", 3.0)
    process = FakeProcess(live=True)
    use_readable_browser(monkeypatch, live=True, process=process)
    calls = stub_storage(monkeypatch)

    closed = []

    def close(closed_process):
        closed.append(closed_process)
        closed_process.live = False  # the window shuts, flushing its store

    # The store is only readable once the window is gone, exactly as a real
    # Chromium profile is, so this can only pass if the close really happened.
    monkeypatch.setattr(
        browser_auth, "read_profile_cookies",
        lambda profile: dict(GOOD_JAR) if closed else None,
    )
    monkeypatch.setattr(browser_auth, "close_browser_window", close)

    start_sign_in(client)

    state = wait_for_session_to_settle(client, seconds=20)
    assert state["state"] == "success", state
    assert closed == [process]
    assert calls["stored"] == [dict(GOOD_JAR)]


def test_finishing_the_sign_in_closes_the_window_and_reads_it(client, monkeypatch):
    """The app's "I've signed in" is the user closing the window, for them."""
    process = FakeProcess(live=True)
    use_readable_browser(monkeypatch, live=True, process=process)
    calls = stub_storage(monkeypatch)

    closed = []

    def close(closed_process):
        closed.append(closed_process)
        closed_process.live = False  # the window shuts, flushing its store

    # Readable only once it is gone, as a real Chromium profile is.
    monkeypatch.setattr(
        browser_auth, "read_profile_cookies",
        lambda profile: dict(GOOD_JAR) if closed else None,
    )
    monkeypatch.setattr(browser_auth, "close_browser_window", close)

    start_sign_in(client)
    assert client.get("/auth/browser/status").json()["state"] == "waiting"

    body = client.post("/auth/browser/finish").json()
    assert body["state"] == "waiting", "the read still has to happen"

    state = wait_for_session_to_settle(client, seconds=15)
    assert state["state"] == "success", state
    assert closed == [process]
    assert calls["stored"] == [dict(GOOD_JAR)]


def test_finishing_with_no_attempt_in_flight_is_idle_not_an_error(client):
    main._clear_browser_session()
    body = client.post("/auth/browser/finish").json()
    assert body["state"] == "idle"


def test_cancel_stops_the_attempt(client):
    start_sign_in(client)
    body = client.post("/auth/browser/cancel").json()
    assert body["state"] == "cancelled"
    # Cancelling retires the attempt, so status falls back to idle rather than
    # leaving a stale object the app would poll forever.
    assert client.get("/auth/browser/status").json()["state"] == "idle"


def test_cancel_while_the_window_is_still_starting_still_closes_it(client, monkeypatch):
    """A window nobody can close yet is still closed once there is one.

    Cancel arrives while the browser is starting, so there is no process for it
    to close -- the launch has to notice it is no longer wanted and take the
    window with it, or the user is left with a browser they cancelled.
    """
    closed = []
    opening = threading.Event()
    release = threading.Event()
    process = FakeProcess(live=True)

    def slow_launch(url, profile):
        opening.set()
        release.wait(5)  # the cancel lands while this is in flight
        return "Microsoft Edge", str(profile), process

    monkeypatch.setattr(browser_auth, "launch_readable_browser", slow_launch)
    monkeypatch.setattr(
        browser_auth, "close_browser_window", lambda p: closed.append(p)
    )

    start_sign_in(client)
    assert opening.wait(5), "the launch never started"

    assert client.post("/auth/browser/cancel").json()["state"] == "cancelled"
    assert closed == [], "there was nothing to close yet"

    release.set()
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and not closed:
        time.sleep(0.05)
    assert closed == [process], "the window of a cancelled attempt stayed open"


def test_status_is_idle_before_any_attempt(client):
    main._clear_browser_session()
    state = client.get("/auth/browser/status").json()
    assert state["state"] == "idle"
    assert state["browser"]


# ------------------------------------------------- session preservation (M2)


def test_refused_capture_leaves_an_existing_session_untouched(client, monkeypatch):
    """The core M2 guarantee: a bad attempt must not damage a working session."""
    existing = b"previously-valid-encrypted-blob"
    os.makedirs(os.path.dirname(ytc._AUTH_FILE), exist_ok=True)
    with open(ytc._AUTH_FILE, "wb") as f:
        f.write(existing)

    use_readable_browser(monkeypatch, cookies=dict(GOOD_JAR))

    def reject(_cookies):
        raise RuntimeError("401 from upstream")

    calls = stub_storage(monkeypatch, verify=reject)

    start_sign_in(client)
    wait_for_session_to_settle(client)

    assert calls["stored"] == [], "a rejected capture must never reach storage"
    with open(ytc._AUTH_FILE, "rb") as f:
        assert f.read() == existing, "the existing session must not be overwritten"


# ------------------------------------------------------------------ sign out


def test_sign_out_removes_the_sign_in_browser_profile(client, monkeypatch, tmp_path):
    """Signing out must not leave the window's Google session behind."""
    profile = tmp_path / "sonore" / "sign-in-browser"
    (profile / "Default").mkdir(parents=True)
    monkeypatch.setattr(browser_cookies, "browser_profile_dir", lambda: str(profile))

    assert profile.exists()
    assert client.post("/auth/signout").status_code == 200
    assert not profile.exists(), "the signed-in browser profile must be removed"


# ------------------------------------------------------------ secret handling


def test_no_cookie_value_is_ever_logged(client, monkeypatch, caplog):
    use_readable_browser(monkeypatch, cookies=dict(GOOD_JAR))
    stub_storage(monkeypatch)

    with caplog.at_level(logging.DEBUG):
        start_sign_in(client)
        wait_for_session_to_settle(client)
        client.get("/auth/status")
        client.get("/auth/browser/status")

    logged = "\n".join(record.getMessage() for record in caplog.records)
    assert COOKIE_VALUE_MARKER not in logged, "cookie values must never reach the log"
