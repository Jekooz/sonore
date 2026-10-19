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
  no controllable browser is reported, the sign-in profile lives in a tmp dir
  and the zero-click reader is replaced, so a test can never launch Edge or read
  the machine's own Firefox cookies.
* Only the success paths stub the network (verify_candidate) and disk
  (store_session); every rejection test runs against the real, unpatched code —
  that is exactly what it is checking.
"""

import logging
import os
import sys
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
    monkeypatch.setattr(
        browser_auth, "webbrowser",
        types.SimpleNamespace(open_new_tab=lambda url: None),
    )
    monkeypatch.setattr(
        browser_auth, "find_controllable_browser", lambda: None, raising=False
    )
    monkeypatch.setattr(
        browser_auth, "browser_profile_dir", lambda: str(sonore / "sign-in-browser"),
        raising=False,
    )
    monkeypatch.setattr(main, "cookies_from_firefox", lambda: None)

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


def use_controllable_browser(monkeypatch, cookies=None, port=9222):
    """Make the capture path behave as if a sign-in window produced a session."""
    monkeypatch.setattr(
        browser_auth, "find_controllable_browser",
        lambda: ("Microsoft Edge", r"C:\Edge\msedge.exe"),
    )
    launched = []
    monkeypatch.setattr(
        browser_auth, "launch_controllable_browser",
        lambda url, profile: launched.append((url, profile)) or port,
    )
    monkeypatch.setattr(
        browser_auth, "read_devtools_cookies",
        lambda p, deadline: cookies,
        raising=False,
    )
    return launched


# ------------------------------------------------------------ start / shape


def test_start_reports_a_waiting_attempt_with_no_pairing_token(client):
    body = start_sign_in(client)
    assert body["state"] == "waiting"
    assert "token" not in body, "the pairing token is gone with the extension"
    assert body.get("error") is None


def test_browser_info_names_the_browser_sign_in_will_drive(client, monkeypatch):
    monkeypatch.setattr(
        main, "find_controllable_browser",
        lambda: ("Microsoft Edge", r"C:\Edge\msedge.exe"),
    )
    resp = client.get("/auth/browser/info")
    assert resp.status_code == 200, resp.text
    assert resp.json()["browser"] == "Microsoft Edge"


def test_start_opens_a_window_in_a_profile_the_app_owns(client, monkeypatch):
    launched = use_controllable_browser(monkeypatch, cookies=None)
    start_sign_in(client)

    deadline = time.monotonic() + 5
    while not launched and time.monotonic() < deadline:
        time.sleep(0.05)
    assert len(launched) == 1, "a real sign-in must open exactly one window"
    url, profile = launched[0]
    assert url == browser_auth.MUSIC_URL
    assert "sign-in-browser" in profile


def test_open_browser_false_neither_reads_nor_launches(client, monkeypatch):
    """The paste-headers fallback supplies the session itself."""
    def explode():
        raise AssertionError("the paste flow must not read a browser")

    monkeypatch.setattr(main, "cookies_from_firefox", explode)
    monkeypatch.setattr(
        browser_auth, "find_controllable_browser",
        lambda: ("Microsoft Edge", r"C:\Edge\msedge.exe"),
    )
    monkeypatch.setattr(
        browser_auth, "launch_controllable_browser",
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
    monkeypatch.setattr(main, "cookies_from_firefox", lambda: dict(GOOD_JAR))
    monkeypatch.setattr(
        browser_auth, "launch_controllable_browser",
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
        main, "cookies_from_firefox",
        lambda: {"YSC": "x", "VISITOR_INFO1_LIVE": "y"},
    )
    monkeypatch.setattr(
        browser_auth, "find_controllable_browser", lambda: None
    )
    calls = stub_storage(monkeypatch)

    start_sign_in(client)
    time.sleep(0.3)

    assert calls["stored"] == [], "an anonymous jar must never be stored"
    # And it must fall through to the window rather than failing.
    assert client.get("/auth/browser/status").json()["state"] == "waiting"


def test_zero_click_refusal_falls_through_to_the_window(client, monkeypatch):
    """A stale Firefox session is not fatal: the user can sign in again."""
    monkeypatch.setattr(main, "cookies_from_firefox", lambda: dict(GOOD_JAR))
    use_controllable_browser(monkeypatch, cookies=None)

    def reject(_cookies):
        raise RuntimeError("401 from upstream")

    stub_storage(monkeypatch, verify=reject)

    start_sign_in(client)
    time.sleep(0.4)
    assert client.get("/auth/browser/status").json()["state"] == "waiting"


# ------------------------------------------------------------ captured window


def test_session_from_the_window_signs_in(client, monkeypatch):
    use_controllable_browser(monkeypatch, cookies=dict(GOOD_JAR))
    calls = stub_storage(monkeypatch)

    start_sign_in(client)

    state = wait_for_session_to_settle(client)
    assert state["state"] == "success", state
    assert calls["stored"] == [dict(GOOD_JAR)]


def test_window_session_refused_by_youtube_fails_the_attempt(client, monkeypatch):
    """The required cookies are present, so this is a real refusal, not a retry."""
    use_controllable_browser(monkeypatch, cookies=dict(GOOD_JAR))

    def reject(_cookies):
        raise main.AuthError("Session expired or invalid. Please sign in again.")

    calls = stub_storage(monkeypatch, verify=reject)

    start_sign_in(client)

    state = wait_for_session_to_settle(client)
    assert state["state"] == "failed", state
    assert "sign in again" in (state["error"] or "").lower()
    assert calls["stored"] == [], "a refused candidate must never reach storage"


def test_cancel_stops_the_attempt(client):
    start_sign_in(client)
    body = client.post("/auth/browser/cancel").json()
    assert body["state"] == "cancelled"
    # Cancelling retires the attempt, so status falls back to idle rather than
    # leaving a stale object the app would poll forever.
    assert client.get("/auth/browser/status").json()["state"] == "idle"


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

    use_controllable_browser(monkeypatch, cookies=dict(GOOD_JAR))

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
    use_controllable_browser(monkeypatch, cookies=dict(GOOD_JAR))
    stub_storage(monkeypatch)

    with caplog.at_level(logging.DEBUG):
        start_sign_in(client)
        wait_for_session_to_settle(client)
        client.get("/auth/status")
        client.get("/auth/browser/status")

    logged = "\n".join(record.getMessage() for record in caplog.records)
    assert COOKIE_VALUE_MARKER not in logged, "cookie values must never reach the log"
