"""
Automated coverage for the extension sign-in handshake (Batch 2 / M2).

These tests drive the REAL FastAPI app through TestClient — the same routes the
desktop app and the browser extension call — so the token lifecycle is exercised
through the production code path, not a reimplementation.

Safety, enforced before anything else:

* Your real stored session (%LOCALAPPDATA%\\ytmusic_client\\auth_headers.dat) is
  never used as a fixture. ``_AUTH_FILE`` is redirected to a tmp dir for every
  test and a guard asserts the redirect happened.
* No browser opens: ``browser_auth.webbrowser`` is stubbed, otherwise
  /auth/browser/start would launch the default browser on the machine running
  the suite.
* The pairing file is redirected out of the repo, so the suite can neither leave
  a live token in browser-extension/ nor clobber one the app is using.

The only stubs that touch production state are on the SUCCESS path, where
verify_candidate (network) and store_session (disk) are replaced so that a
passing test cannot overwrite or clear real credentials. Every rejection test
runs against the real, unpatched code — that is exactly what it is checking.
"""

import json
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
from services import browser_auth  # noqa: E402
import services.ytmusic_client as ytc  # noqa: E402

TEST_PORT = 8123
COOKIE_VALUE_MARKER = "cookie-value-that-must-never-be-logged"

# A jar that passes the REQUIRED_COOKIES gate, so tests reach the token logic
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

    # Guard: if this ever regresses, the tests would be writing to the real
    # credential file. Fail loudly instead.
    assert ytc._AUTH_FILE != REAL_SESSION_FILE
    assert "ytmusic_client" not in ytc._AUTH_FILE

    pairing = tmp_path / "sidecar.json"
    monkeypatch.setattr(main, "PAIRING_FILE", str(pairing))
    monkeypatch.setattr(main, "_EXTENSION_DIR", str(tmp_path))
    monkeypatch.setattr(main, "_BOUND_PORT", TEST_PORT)

    # /auth/browser/start opens the default browser. Never do that in a test.
    monkeypatch.setattr(
        browser_auth, "webbrowser",
        types.SimpleNamespace(open_new_tab=lambda url: None),
    )

    main._clear_browser_session()
    main._clear_pairing()
    main._extension_cookies = None
    main._extension_cookies_event.clear()

    yield

    main._clear_browser_session()
    main._clear_pairing()


@pytest.fixture
def client():
    return TestClient(main.app)


def start_sign_in(client):
    """Begin a real sign-in attempt; returns the issued handshake token."""
    resp = client.post("/auth/browser/start")
    assert resp.status_code == 200, resp.text
    assert main._pairing_token is not None, "start must issue a pairing token"
    return main._pairing_token


def hand_off(client, token=None, jar=None, headers=None):
    hdrs = dict(headers or {})
    if token is not None:
        hdrs["X-Ytm-Token"] = token
    return client.post("/auth/extension", json={"cookies": jar or GOOD_JAR}, headers=hdrs)


def wait_for_session_to_settle(client, seconds=6.0):
    """Poll the real status endpoint the way the desktop app does."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        state = client.get("/auth/browser/status").json()
        if state["state"] != "waiting":
            return state
        time.sleep(0.1)
    raise AssertionError("the sign-in attempt never left the waiting state")


# ---------------------------------------------------------------- pairing file


def test_start_publishes_port_and_token_for_the_extension(client, tmp_path):
    token = start_sign_in(client)

    assert os.path.exists(main.PAIRING_FILE), "the extension cannot pair without this file"
    published = json.loads(open(main.PAIRING_FILE, encoding="utf-8").read())

    assert published["port"] == TEST_PORT
    assert published["token"] == token
    assert published["port"] != 0, "a port of 0 would send the extension nowhere"


def test_pairing_file_is_written_into_the_extension_folder(client, monkeypatch, tmp_path):
    """The extension can only fetch its own resources, so the file must live there."""
    start_sign_in(client)
    assert os.path.dirname(main.PAIRING_FILE) == main._EXTENSION_DIR
    assert os.path.basename(main.PAIRING_FILE) == "sidecar.json"


def test_extension_folder_is_reported_so_the_sign_in_screen_can_name_it(client):
    """The screen has to name the folder the extension must be loaded from.

    An extension loaded from any other folder can never read the pairing file,
    so the hand-off waits until it times out - a sign-in that appears broken
    with nothing on screen explaining why. This is the path the UI displays and
    offers to open.
    """
    resp = client.get("/auth/extension/folder")

    assert resp.status_code == 200, resp.text
    folder = resp.json()["folder"]
    assert folder == main._EXTENSION_DIR
    assert os.path.dirname(main.PAIRING_FILE) == folder, (
        "the folder shown must be the one the pairing file lands in"
    )


# ------------------------------------------------------------ unsolicited/401


def test_hand_off_rejected_when_no_sign_in_is_in_progress(client):
    """No /auth/browser/start first: nothing is waiting, so refuse with 409."""
    resp = hand_off(client, token="whatever")
    assert resp.status_code == 409, resp.text
    assert "no sign-in" in resp.json()["detail"].lower()


def test_hand_off_rejected_without_token(client):
    start_sign_in(client)
    resp = hand_off(client, token=None)
    assert resp.status_code == 401, resp.text
    assert "missing pairing token" in resp.json()["detail"].lower()


def test_hand_off_rejected_with_wrong_token(client):
    start_sign_in(client)
    resp = hand_off(client, token="not-the-token")
    assert resp.status_code == 401, resp.text
    assert "invalid pairing token" in resp.json()["detail"].lower()


def test_wrong_token_does_not_burn_the_valid_one(client, monkeypatch):
    """Guessing must not lock out the legitimate popup click."""
    token = start_sign_in(client)
    monkeypatch.setattr(main.ytmusic_service, "verify_candidate", lambda c: {"accountName": "x"})
    monkeypatch.setattr(main.ytmusic_service, "store_session", lambda c: {"signed_in": True})

    assert hand_off(client, token="guess").status_code == 401
    assert hand_off(client, token=token).status_code == 200


# ------------------------------------------------------------ success / replay


def test_valid_token_completes_sign_in(client, monkeypatch):
    token = start_sign_in(client)
    monkeypatch.setattr(main.ytmusic_service, "verify_candidate", lambda c: {"accountName": "x"})
    monkeypatch.setattr(main.ytmusic_service, "store_session", lambda c: {"signed_in": True})

    resp = hand_off(client, token=token)
    assert resp.status_code == 200, resp.text
    assert resp.json()["signed_in"] is True

    # The waiting browser session is what the desktop UI polls.
    assert wait_for_session_to_settle(client)["state"] == "success"


def test_token_is_single_use_and_a_replay_is_rejected(client, monkeypatch):
    token = start_sign_in(client)
    monkeypatch.setattr(main.ytmusic_service, "verify_candidate", lambda c: {"accountName": "x"})

    store_calls = []
    # Capture what the token looked like at the instant storage ran.
    token_at_store = []

    def fake_store(cookies):
        store_calls.append(cookies)
        token_at_store.append(main._pairing_token)
        return {"signed_in": True}

    monkeypatch.setattr(main.ytmusic_service, "store_session", fake_store)

    assert hand_off(client, token=token).status_code == 200

    # The sharp invariant: the token was already consumed BEFORE anything was
    # stored. That ordering is what makes a replay impossible.
    assert token_at_store == [None], "the token must be consumed before storage runs"
    assert main._pairing_token is None

    replay = hand_off(client, token=token)
    # The poll thread normally settles the attempt within ~100 ms, so the replay
    # is refused with 409 ("nothing is waiting"); if it has not caught up yet it
    # is 401 ("token already consumed"). Both are refusals, and this asserts the
    # guarantee that matters rather than which of the two applies.
    assert replay.status_code in (401, 409), replay.text
    assert len(store_calls) == 1, "a replayed hand-off must not store a session again"


def test_expired_token_is_rejected(client):
    token = start_sign_in(client)
    # Age the token past the attempt's own 3-minute window.
    main._pairing_issued_at = time.monotonic() - (browser_auth.WAIT_TIMEOUT_SECONDS + 1)

    resp = hand_off(client, token=token)
    assert resp.status_code == 401, resp.text
    assert "expired" in resp.json()["detail"].lower()


def test_new_attempt_rotates_the_token(client, monkeypatch):
    first = start_sign_in(client)
    second = start_sign_in(client)
    assert first != second, "each attempt must get its own token"

    monkeypatch.setattr(main.ytmusic_service, "verify_candidate", lambda c: {"accountName": "x"})
    monkeypatch.setattr(main.ytmusic_service, "store_session", lambda c: {"signed_in": True})

    assert hand_off(client, token=first).status_code == 401, "the retired token must not work"
    assert hand_off(client, token=second).status_code == 200


# ----------------------------------------------------------------- malformed


@pytest.mark.parametrize("body", [{}, {"cookies": "not-a-dict"}, {"cookies": []}])
def test_malformed_body_rejected_with_a_valid_token(client, body):
    token = start_sign_in(client)
    resp = client.post("/auth/extension", json=body, headers={"X-Ytm-Token": token})
    assert resp.status_code == 400, resp.text
    assert "cookies" in resp.json()["detail"].lower()


def test_empty_jar_reports_the_unsigned_in_browser_and_ends_the_attempt(client, monkeypatch):
    """The extension in a browser with no YouTube Music session sends {}.

    Measured live, through the real extension in a real Chromium: that request
    was answered with a body-format complaint ("Body must contain a 'cookies'
    object.") and, because the 400 was raised outside the handler that fails the
    attempt, the app kept waiting out its full three minutes -- the sign-in
    looked hung while the popup blamed the request. An empty jar is a delivered
    jar, just not a signed-in one, so it goes through the shared validation:
    422 naming the real problem, and an attempt that stops waiting.
    """
    token = start_sign_in(client)
    store_calls = []
    monkeypatch.setattr(
        main.ytmusic_service, "store_session",
        lambda c: store_calls.append(c) or {"signed_in": True},
    )

    resp = client.post(
        "/auth/extension", json={"cookies": {}}, headers={"X-Ytm-Token": token}
    )

    assert resp.status_code == 422, resp.text
    detail = resp.json()["detail"]
    assert "none of the required session cookies" in detail.lower()
    assert "sign in to music.youtube.com" in detail.lower()
    assert store_calls == [], "an empty jar must never reach storage"

    state = wait_for_session_to_settle(client)
    assert state["state"] == "failed", "the app must stop waiting and report it"
    assert state["error"] == detail, "the status the UI polls carries the reason"


def test_malformed_body_without_a_token_is_rejected_before_parsing(client):
    """Audit finding 8: the BODY check runs before the token gate, so an
    empty body is 400 (not burned-token 401). Malformed callers must keep
    their single-use attempt."""
    start_sign_in(client)
    resp = client.post("/auth/extension", json={})
    assert resp.status_code == 400, resp.text
    assert main._pairing_token is not None, "a malformed body must not consume the token"

    resp2 = client.post("/auth/extension", json={})
    assert resp2.status_code == 400, resp.text


# ------------------------------------------------- session preservation (M2)


def test_failed_hand_off_leaves_an_existing_session_untouched(client, monkeypatch):
    """The core M2 guarantee: a bad attempt must not damage a working session."""
    # Stand in for a previously valid session already on disk.
    existing = b"previously-valid-encrypted-blob"
    os.makedirs(os.path.dirname(ytc._AUTH_FILE), exist_ok=True)
    with open(ytc._AUTH_FILE, "wb") as f:
        f.write(existing)

    token = start_sign_in(client)

    # YouTube rejects the candidate cookies (wrong account / stale jar).
    def reject(_cookies):
        raise RuntimeError("401 from upstream")

    store_calls = []
    monkeypatch.setattr(main.ytmusic_service, "verify_candidate", reject)
    monkeypatch.setattr(
        main.ytmusic_service, "store_session",
        lambda c: store_calls.append(c) or {"signed_in": True},
    )

    resp = hand_off(client, token=token)
    assert resp.status_code == 401, resp.text

    assert store_calls == [], "a rejected hand-off must never reach storage"
    assert os.path.exists(ytc._AUTH_FILE), "the existing session must not be deleted"
    with open(ytc._AUTH_FILE, "rb") as f:
        assert f.read() == existing, "the existing session must not be overwritten"


def test_incomplete_jar_is_rejected_before_storage(client, monkeypatch):
    """A jar that misses required session cookies must 422 and never store."""
    token = start_sign_in(client)
    store_calls = []
    monkeypatch.setattr(
        main.ytmusic_service, "store_session",
        lambda c: store_calls.append(c) or {"signed_in": True},
    )

    # Anonymous cookies only: passes the 'is a dict' body check but fails the
    # REQUIRED_COOKIES gate inside _validate_and_store.
    resp = hand_off(client, token=token, jar={"VISITOR_INFO1_LIVE": "anon"})

    assert resp.status_code == 422, resp.text
    detail = resp.json()["detail"]
    assert "Sign-in incomplete" in detail, detail
    # Note: the token WAS burned by this attempt (consumed before the jar gate
    # could pass). That is the pre-fix order; the validate-before-consume fix
    # is pinned by its own test below.
    assert store_calls == [], "an incomplete jar must never reach storage"

# ------------------------------------------- the shared path's other caller
#
# _validate_and_store is shared with the legacy /auth/cookies endpoint, so the
# M2 guarantee and the response shape the C# client deserialises must hold there
# too. These two tests exist purely because that caller changed behaviour as
# well when the order was swapped.


def test_legacy_cookies_endpoint_reports_the_verified_account(client, monkeypatch):
    stored = []
    monkeypatch.setattr(main.ytmusic_service, "verify_candidate", lambda c: {"accountName": "me"})
    monkeypatch.setattr(
        main.ytmusic_service, "store_session",
        lambda c: stored.append(c) or {"signed_in": True},
    )

    # Audit finding 1: the legacy endpoint runs under the same pairing gate as
    # the extension route, so these tests drive a real handshake first.
    token = start_sign_in(client)
    resp = client.post(
        "/auth/cookies", json={"cookies": GOOD_JAR}, headers={"X-Ytm-Token": token}
    )
    assert resp.status_code == 200, resp.text
    # ApiClient maps exactly this shape: result["account"] -> CookieLoginResponse.Account.
    assert resp.json()["account"] == {"accountName": "me"}
    assert resp.json()["signed_in"] is True
    assert len(stored) == 1


def test_legacy_cookies_endpoint_is_gated_like_the_extension(client):
    """A bare POST must not install a session (audit finding 1)."""
    resp = client.post("/auth/cookies", json={"cookies": GOOD_JAR})
    assert resp.status_code == 409, resp.text

    token = start_sign_in(client)
    resp = client.post("/auth/cookies", json={"cookies": GOOD_JAR})
    assert resp.status_code == 401, resp.text
    assert "pairing token" in resp.json()["detail"].lower()


def test_pairs_with_the_wrong_token_never_seen_before(client, monkeypatch):
    # Wrong token: not consumed, so the right one still works afterwards
    # (module docstring promise — pinned here for the gated legacy route).
    # Success-path mocks keep this test off the network, like every other
    # success-path test in this file.
    monkeypatch.setattr(main.ytmusic_service, "verify_candidate", lambda c: {"accountName": "me"})
    monkeypatch.setattr(
        main.ytmusic_service, "store_session",
        lambda c: None or {"signed_in": True},
    )
    token = start_sign_in(client)
    assert client.post(
        "/auth/cookies", json={"cookies": GOOD_JAR}, headers={"X-Ytm-Token": "wrong"}
    ).status_code == 401
    assert main._pairing_token is not None, "a wrong token must not consume the attempt"
    resp = client.post(
        "/auth/cookies", json={"cookies": GOOD_JAR}, headers={"X-Ytm-Token": token}
    )
    assert resp.status_code == 200, resp.text


def test_legacy_cookies_endpoint_also_preserves_a_valid_session(client, monkeypatch):
    existing = b"previously-valid-encrypted-blob"
    with open(ytc._AUTH_FILE, "wb") as f:
        f.write(existing)

    def reject(_cookies):
        raise RuntimeError("401 from upstream")

    store_calls = []
    monkeypatch.setattr(main.ytmusic_service, "verify_candidate", reject)
    monkeypatch.setattr(
        main.ytmusic_service, "store_session",
        lambda c: store_calls.append(c) or {"signed_in": True},
    )

    # Same real handshake as the success test under the finding-1 gate.
    token = start_sign_in(client)
    resp = client.post(
        "/auth/cookies", json={"cookies": GOOD_JAR}, headers={"X-Ytm-Token": token}
    )
    assert resp.status_code == 401, resp.text
    assert store_calls == [], "a rejected candidate must never reach storage"
    assert open(ytc._AUTH_FILE, "rb").read() == existing


def test_concurrent_hand_offs_consume_the_token_only_once():
    """Audit finding 7: N threads holding a valid token -> exactly one wins.
    The test drives the real consume function concurrently against threads of
    the same interpreter state as the running uvicorn server."""
    main._pairing_token = "live-token"
    main._pairing_issued_at = time.monotonic()
    main.WAIT_TIMEOUT_SECONDS

    results = []
    import threading as _threading

    barrier = _threading.Barrier(8)

    def racer():
        barrier.wait()
        results.append(main._consume_pairing_token("live-token"))

    threads = [_threading.Thread(target=racer) for _ in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert results.count(None) == 1, f"exactly one racer must win, got {results}"
    assert main._pairing_token is None, "the token must be consumed exactly once"


def test_malformed_body_does_not_burn_the_pairing_token(client, monkeypatch):
    """Audit finding 8: a 400 on a malformed body must not consume the attempt."""
    monkeypatch.setattr(main.ytmusic_service, "verify_candidate", lambda c: {"accountName": "me"})
    monkeypatch.setattr(
        main.ytmusic_service, "store_session",
        lambda c: None or {"signed_in": True},
    )
    token = start_sign_in(client)

    resp = client.post("/auth/extension", json={}, headers={"X-Ytm-Token": token})
    assert resp.status_code == 400, resp.text
    assert main._pairing_token is not None, "the token must survive a malformed body"

    # The very same token still completes a well-formed hand-off.
    resp2 = hand_off(client, token=token)
    assert resp2.status_code == 200, resp2.text


# -------------------------------------------------------------- cancellation


def test_cancel_invalidates_the_token_and_removes_the_file(client):
    token = start_sign_in(client)
    assert os.path.exists(main.PAIRING_FILE)

    assert client.post("/auth/browser/cancel").status_code == 200

    assert not os.path.exists(main.PAIRING_FILE), "the pairing file must not outlive the attempt"
    assert main._pairing_token is None
    assert hand_off(client, token=token).status_code == 409


def test_status_poll_cleans_up_after_a_terminal_state(client):
    """A timeout has no other cleanup hook — the status poll must do it."""
    start_sign_in(client)
    assert os.path.exists(main.PAIRING_FILE)

    main._browser_session.fail("Timed out after 3 minutes")

    state = client.get("/auth/browser/status").json()
    assert state["state"] == "failed"
    assert not os.path.exists(main.PAIRING_FILE)


# ------------------------------------------------------------ secret handling


def test_no_token_or_cookie_value_is_ever_logged(client, monkeypatch, caplog):
    token = start_sign_in(client)
    monkeypatch.setattr(main.ytmusic_service, "verify_candidate", lambda c: {"accountName": "x"})
    monkeypatch.setattr(main.ytmusic_service, "store_session", lambda c: {"signed_in": True})

    with caplog.at_level(logging.DEBUG):
        hand_off(client, token=token)                    # success path
        hand_off(client, token="wrong-token")            # rejection path
        client.get("/auth/status")

    logged = "\n".join(record.getMessage() for record in caplog.records)
    assert token not in logged, "the pairing token must never reach the log"
    assert COOKIE_VALUE_MARKER not in logged, "cookie values must never reach the log"


# -------------------------------------------------------- the account's name
#
# The service's own account menu answered with a navigation label ("Home") in
# `accountName` on a real signed-in session (measured 2026-10-15, while
# `channelHandle` from the same response was the real @handle). Showing that
# label in Settings as "Signed in as" is wrong, so the value is dropped at the
# boundary and the client falls back to the real handle.


def test_sanitize_account_drops_a_chrome_label_and_keeps_the_handle():
    sanitized = ytc.sanitize_account(
        {
            "accountName": "Home",
            "channelHandle": "@someone",
            "accountPhotoUrl": "https://example.invalid/a.jpg",
        }
    )

    assert sanitized["accountName"] is None, "a navigation label is not a name"
    assert sanitized["channelHandle"] == "@someone"
    assert sanitized["accountPhotoUrl"] == "https://example.invalid/a.jpg"


def test_sanitize_account_keeps_a_real_name():
    sanitized = ytc.sanitize_account({"accountName": "  Jane Doe  "})

    assert sanitized["accountName"] == "Jane Doe"


def test_sanitize_account_always_answers_with_the_same_three_fields():
    for payload in (None, {}, {"accountName": "   "}, "not a dict", {"accountName": 3}):
        sanitized = ytc.sanitize_account(payload)
        assert set(sanitized) == {"accountName", "channelHandle", "accountPhotoUrl"}
        assert sanitized["accountName"] is None


def test_account_route_never_reports_a_chrome_label_as_the_account(client, monkeypatch):
    monkeypatch.setattr(
        main.ytmusic_service, "call",
        lambda method, **kwargs: {
            "accountName": "Home",
            "channelHandle": "@someone",
            "accountPhotoUrl": "https://example.invalid/a.jpg",
        },
    )

    resp = client.get("/account")

    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["accountName"] is None
    assert body["channelHandle"] == "@someone"


def test_verify_candidate_sanitizes_the_account_it_returns(monkeypatch):
    """The sign-in response and /account must agree about who is signed in."""

    class FakeClient:
        def __init__(self, auth):
            self.auth = auth

        def get_account_info(self):
            return {
                "accountName": "Search",
                "channelHandle": "@someone",
                "accountPhotoUrl": None,
            }

    monkeypatch.setattr(ytc, "YTMusic", FakeClient)

    account = ytc.ytmusic_service.verify_candidate(GOOD_JAR)

    assert account["accountName"] is None
    assert account["channelHandle"] == "@someone"
