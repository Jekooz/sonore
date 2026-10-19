"""
Coverage for the loopback-only browse hand-off endpoint (POST /auth/handoff).

Same rules as test_auth_capture.py: these tests drive the REAL FastAPI app
through TestClient, isolation of the real credential file is enforced by the
imported ``isolated_env`` fixture, and only the success path stubs the network
(verify_candidate) and disk (store_session). Every rejection test runs against
the real, unpatched code.

The one structural difference from that suite: the client is built with a
loopback base_url on purpose, because /auth/handoff rejects any Host header
that is not 127.0.0.1/localhost -- TestClient's default "testserver" host is
exactly the non-local name the endpoint must refuse, which is itself asserted
in the non-loopback tests.
"""

import json
import time

import pytest
from fastapi.testclient import TestClient

from test_auth_capture import (  # noqa: F401  (fixtures are picked up by name)
    GOOD_JAR,
    TEST_PORT,
    api_token,
    isolated_env,
    start_sign_in,
    stub_storage,
    wait_for_session_to_settle,
)

import main  # noqa: E402
from services import browser_auth  # noqa: E402

# Cookie values that must never appear in a log line.
SECRET_MARKER = "cookie-value-that-must-never-be-logged"

LOOPBACK_BASE = "http://127.0.0.1:8123"

pytestmark = pytest.mark.usefixtures("isolated_env")


@pytest.fixture
def client():
    """The real app, addressed the way the app and the paste fallback address it."""
    return TestClient(main.app, base_url=LOOPBACK_BASE)


def start(client, payload=None):
    """Begin an attempt; returns (state, browser) exactly as the app reads them."""
    resp = client.post("/auth/browser/start", json=payload or {})
    assert resp.status_code == 200, resp.text
    body = resp.json()
    return body["state"], body.get("browser")


def post_handoff(client, body, api_token=None):
    headers = {}
    if api_token is not None:
        headers["X-Sonore-Token"] = api_token
    return client.post("/auth/handoff", json=body, headers=headers)


def good_jar():
    return {name: SECRET_MARKER for name in GOOD_JAR}


# ---------------------------------------------------------------- happy path


def test_valid_hand_off_stores_and_settles_the_attempt(client, monkeypatch, api_token):
    seen = {}

    def fake_verify(cookies, headers=None):
        seen["headers"] = headers
        return {"accountName": "x"}

    def fake_store(cookies, headers=None):
        seen["stored_headers"] = headers
        return {"signed_in": True}

    monkeypatch.setattr(main.ytmusic_service, "verify_candidate", fake_verify)
    monkeypatch.setattr(main.ytmusic_service, "store_session", fake_store)
    start(client)

    resp = post_handoff(
        client,
        {
            "cookies": good_jar(),
            "headers": {"user-agent": "UA-Handoff/1.0", "x-youtube-client-name": "67"},
        },
        api_token=api_token,
    )

    assert resp.status_code == 200, resp.text
    assert resp.json()["signed_in"] is True
    assert resp.json()["account"] == {"accountName": "x"}
    # The browser's own headers reached the auth build, not just the jar.
    assert seen["stored_headers"]["user-agent"] == "UA-Handoff/1.0"
    # The desktop UI polls this exact endpoint, so the attempt must settle.
    assert wait_for_session_to_settle(client)["state"] == "success"


def test_hand_off_headers_are_normalised_before_use(client, monkeypatch, api_token):
    seen = {}

    def fake_store(cookies, headers=None):
        seen["stored_headers"] = headers
        return {"signed_in": True}

    monkeypatch.setattr(main.ytmusic_service, "verify_candidate", lambda c, h=None: {"accountName": "x"})
    monkeypatch.setattr(main.ytmusic_service, "store_session", fake_store)
    start(client)

    resp = post_handoff(
        client,
        {"cookies": good_jar(), "headers": {"User-Agent": "UA-Caps/2.0"}},
        api_token=api_token,
    )

    assert resp.status_code == 200, resp.text
    assert seen["stored_headers"]["user-agent"] == "UA-Caps/2.0"


# ---------------------------------------------------------- attempt lifecycle


def test_hand_off_rejected_with_no_attempt_in_progress(client, api_token):
    resp = post_handoff(client, {"cookies": good_jar()}, api_token=api_token)
    assert resp.status_code == 409, resp.text
    assert "start sign-in" in resp.json()["detail"].lower()


def test_hand_off_requires_the_install_token(client):
    start(client)
    resp = post_handoff(client, {"cookies": good_jar()})
    assert resp.status_code == 401, resp.text
    assert "api token is required" in resp.json()["detail"].lower()


def test_hand_off_rejects_a_wrong_install_token(client):
    start(client)
    resp = post_handoff(client, {"cookies": good_jar()}, api_token="not-the-token")
    assert resp.status_code == 401, resp.text
    assert "not valid" in resp.json()["detail"].lower()


# ------------------------------------------------------------ non-loopback


def test_non_loopback_origin_is_rejected_before_anything_else(client, monkeypatch, api_token):
    """A valid token must not matter: locality is checked first."""
    stub_storage(monkeypatch)  # would make a 200 possible if it got that far
    start(client)

    resp = post_handoff(
        client,
        {"cookies": good_jar()},
        api_token=api_token,
    )
    # sanity: the loopback caller is fine
    assert resp.status_code in (200, 409), resp.text

    resp = client.post(
        "/auth/handoff",
        json={"cookies": good_jar()},
        headers={"X-Sonore-Token": api_token, "Origin": "https://evil.example"},
    )
    assert resp.status_code == 403, resp.text
    assert "not a loopback origin" in resp.json()["detail"]


def test_forged_null_origin_is_rejected(client, monkeypatch, api_token):
    stub_storage(monkeypatch)
    start(client)

    resp = client.post(
        "/auth/handoff",
        json={"cookies": good_jar()},
        headers={"X-Sonore-Token": api_token, "Origin": "null"},
    )
    assert resp.status_code == 403, resp.text


def test_loopback_origin_is_accepted(client, monkeypatch, api_token):
    stub_storage(monkeypatch)
    start(client)

    resp = client.post(
        "/auth/handoff",
        json={"cookies": good_jar()},
        headers={"X-Sonore-Token": api_token, "Origin": "http://127.0.0.1:8123"},
    )
    assert resp.status_code == 200, resp.text


def test_extension_origin_is_no_longer_admitted(client, monkeypatch, api_token):
    """With the extension gone, an extension origin is just another foreign one."""
    stub_storage(monkeypatch)
    start(client)

    resp = client.post(
        "/auth/handoff",
        json={"cookies": good_jar()},
        headers={
            "X-Sonore-Token": api_token,
            "Origin": "chrome-extension://abcdefghijklmnop",
        },
    )
    assert resp.status_code == 403, resp.text


def test_non_loopback_host_is_rejected():
    """DNS rebinding: a name that resolves here still announces itself."""
    client = TestClient(main.app, base_url="http://attacker.example")
    resp = client.post("/auth/handoff", json={"cookies": good_jar()})
    assert resp.status_code == 403, resp.text
    assert "not a loopback" in resp.json()["detail"]


# -------------------------------------------------------------- payload shape


def test_body_that_is_not_json_is_rejected(client):
    start(client)
    resp = client.post(
        "/auth/handoff",
        content="not json at all",
        headers={"Content-Type": "application/json"},
    )
    assert resp.status_code == 400, resp.text


def test_cookies_that_are_not_an_object_are_rejected(client, api_token):
    start(client)
    resp = post_handoff(client, {"cookies": ["SID", "HSID"]}, api_token=api_token)
    assert resp.status_code == 400, resp.text
    assert "JSON object" in resp.json()["detail"]


def test_oversized_body_is_rejected_with_413(client, api_token):
    start(client)
    big = "x" * (main._MAX_HANDOFF_BYTES + 1)
    resp = post_handoff(client, {"headers": {"cookie": big}}, api_token=api_token)
    assert resp.status_code == 413, resp.text


def test_too_many_entries_are_rejected(client, api_token):
    start(client)
    jar = {f"c{i}": "v" for i in range(main._MAX_HANDOFF_ENTRIES + 1)}
    resp = post_handoff(client, {"cookies": jar}, api_token=api_token)
    assert resp.status_code == 400, resp.text
    assert "Too many" in resp.json()["detail"]


def test_oversized_single_value_is_rejected(client, api_token):
    start(client)
    resp = post_handoff(
        client,
        {"cookies": {"SID": "y" * (main._MAX_HANDOFF_VALUE + 1)}},
        api_token=api_token,
    )
    assert resp.status_code == 400, resp.text


# ----------------------------------------------------------------- rejections


def test_empty_payload_is_reported_as_unsigned_in(client, api_token):
    start(client)

    resp = post_handoff(client, {}, api_token=api_token)
    assert resp.status_code == 422, resp.text
    assert "required session cookies" in resp.json()["detail"]


def test_failed_hand_off_leaves_the_stored_session_untouched(client, monkeypatch, api_token):
    stored = []
    monkeypatch.setattr(
        main.ytmusic_service,
        "verify_candidate",
        lambda *a, **k: (_ for _ in ()).throw(
            main.AuthError("Session expired or invalid. Please sign in again.")
        ),
    )
    monkeypatch.setattr(
        main.ytmusic_service,
        "store_session",
        lambda *a, **k: stored.append("should-not-run") or {"signed_in": True},
    )
    start(client)

    resp = post_handoff(client, {"cookies": good_jar()}, api_token=api_token)
    assert resp.status_code == 422, resp.text
    assert stored == []
    # The attempt is failed, not silently waiting.
    assert wait_for_session_to_settle(client)["state"] == "failed"


# -------------------------------------------------------- paste-headers path


def test_start_can_skip_opening_the_browser_for_the_paste_flow(client, monkeypatch):
    opened = []
    monkeypatch.setattr(
        browser_auth,
        "webbrowser",
        __import__("types").SimpleNamespace(open_new_tab=opened.append),
    )
    state, _ = start(client, {"open_browser": False})

    assert state == "waiting"
    time.sleep(0.3)
    assert opened == [], "the paste flow must not open a window"


def test_start_still_opens_the_browser_when_none_is_controllable(client, monkeypatch):
    opened = []
    monkeypatch.setattr(
        browser_auth,
        "webbrowser",
        __import__("types").SimpleNamespace(open_new_tab=opened.append),
    )
    start(client)

    deadline = time.monotonic() + 5
    while not opened and time.monotonic() < deadline:
        time.sleep(0.05)
    assert opened == [browser_auth.MUSIC_URL]


def test_pasted_headers_with_cookie_line_sign_in(client, monkeypatch, api_token):
    stub_storage(monkeypatch)
    start(client, {"open_browser": False})

    cookie_line = "; ".join(f"{k}={v}" for k, v in good_jar().items())
    resp = post_handoff(
        client,
        {"headers": {"cookie": cookie_line, "user-agent": "UA-Paste/3.0"}},
        api_token=api_token,
    )

    assert resp.status_code == 200, resp.text
    assert resp.json()["signed_in"] is True
    assert wait_for_session_to_settle(client)["state"] == "success"


def test_pasted_headers_without_cookie_line_are_rejected(client, api_token):
    start(client, {"open_browser": False})
    resp = post_handoff(
        client, {"headers": {"user-agent": "UA/1.0"}}, api_token=api_token
    )
    assert resp.status_code == 400, resp.text
    assert "cookie:" in resp.json()["detail"]


# -------------------------------------------------------------------- secrecy


def test_no_cookie_or_token_value_is_ever_logged(client, monkeypatch, caplog, api_token):
    stub_storage(monkeypatch)
    start(client)

    with caplog.at_level("DEBUG"):
        post_handoff(
            client,
            {"cookies": good_jar(), "headers": {"user-agent": SECRET_MARKER}},
            api_token=api_token,
        )
        client.get("/auth/status")

    joined = json.dumps([r.getMessage() for r in caplog.records])
    assert SECRET_MARKER not in joined
    assert api_token not in joined
