"""
Lockdown tests for the local API: the per-install token, Origin gating, expired
sessions, and the yt-dlp update path.

Same rules as test_auth_capture.py: these drive the REAL FastAPI app through
TestClient, the imported ``isolated_env`` fixture redirects every piece of
persistent state (credentials, the install token, the update-state file) into a
tmp dir, and only the success paths stub the network/disk. Every rejection test
runs against the real, unpatched code.

The client uses a loopback base_url on purpose: the install-token endpoint and
every data route refuse a Host that is not 127.0.0.1/localhost.
"""

import os
import pathlib
import sys
import time

import pytest
from fastapi.testclient import TestClient

BACKEND_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "backend"
)
if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)

import main  # noqa: E402
from test_auth_capture import (  # noqa: F401  (fixtures are picked up by name)
    TEST_PORT,
    api_token,
    isolated_env,
)

pytestmark = pytest.mark.usefixtures("isolated_env")

# A data endpoint that requires both the install token and a valid session.
DATA_ENDPOINT = "/account"


@pytest.fixture
def client():
    """The real app, addressed the way the desktop app addresses it."""
    return TestClient(main.app, base_url=f"http://127.0.0.1:{TEST_PORT}")


# ---------------------------------------------------------- install token gating


def test_data_endpoint_rejects_missing_install_token(client):
    """No X-Sonore-Token -> 401 on a locked data endpoint."""
    resp = client.get(DATA_ENDPOINT)
    assert resp.status_code == 401, resp.text
    assert "api token is required" in resp.json()["detail"].lower()


def test_data_endpoint_rejects_wrong_install_token(client):
    """Wrong X-Sonore-Token -> 401, and the right one still works afterward."""
    wrong = client.get(DATA_ENDPOINT, headers={"X-Sonore-Token": "not-the-token"})
    assert wrong.status_code == 401, wrong.text
    assert "api token is not valid" in wrong.json()["detail"].lower()


def test_every_data_route_is_locked(client):
    """The token gate covers each account/library/stream route, not just one."""
    routes = [
        ("GET", "/account"),
        ("GET", "/home"),
        ("GET", "/library/playlists"),
        ("GET", "/library/artists"),
        ("GET", "/library/albums"),
        ("GET", "/library/songs"),
        ("GET", "/library/subscriptions"),
        ("GET", "/library/liked"),
        ("GET", "/search?q=test"),
        ("GET", "/radio?videoId=dQw4w9WgXcQ"),
        ("GET", "/recommendations?seed=dQw4w9WgXcQ"),
        ("GET", "/stream/dQw4w9WgXcQ"),
        ("GET", "/lyrics/dQw4w9WgXcQ"),
        ("GET", "/playback/engine"),
        ("POST", "/playback/engine/update"),
    ]
    for method, path in routes:
        resp = client.request(method, path)
        assert resp.status_code == 401, f"{method} {path} -> {resp.status_code}"
        assert "api token is required" in resp.json()["detail"].lower(), path


# -------------------------------------------------------------- Origin gating


def test_data_endpoint_rejects_bad_origin(client, api_token):
    """Origin from a non-loopback web origin -> 403 before anything else."""
    resp = client.get(
        DATA_ENDPOINT,
        headers={"X-Sonore-Token": api_token, "Origin": "https://evil.example"},
    )
    assert resp.status_code == 403, resp.text
    assert "not a loopback origin" in resp.json()["detail"]


def test_data_endpoint_rejects_null_origin(client, api_token):
    """Origin: null is forgeable and is refused."""
    resp = client.get(
        DATA_ENDPOINT,
        headers={"X-Sonore-Token": api_token, "Origin": "null"},
    )
    assert resp.status_code == 403, resp.text


def test_data_endpoint_accepts_loopback_origin(client, api_token, monkeypatch):
    """A loopback Origin is allowed (the Host check alone is not enough)."""
    monkeypatch.setattr(
        main.ytmusic_service,
        "call",
        lambda method, **kwargs: {"accountName": "me"},
    )

    resp = client.get(
        DATA_ENDPOINT,
        headers={"X-Sonore-Token": api_token, "Origin": "http://127.0.0.1:8123"},
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["accountName"] == "me"


# -------------------------------------------------------------- expired session


def test_expired_session_clears_stored_session(client, api_token, monkeypatch):
    """A 401 from the provider drops the session, and the caller sees 401."""
    store: dict[str, object] = {"headers": {"cookie": "SID=stored"}}
    monkeypatch.setattr(main.ytmusic_service, "get_headers", lambda: store["headers"])

    class ExpiredClient:
        def get_account_info(self, *args, **kwargs):
            err = RuntimeError("HTTP 401: Unauthorized")
            err.status = 401
            raise err

    monkeypatch.setattr(main.ytmusic_service, "_get_client", lambda: ExpiredClient())
    # The real clear_session() drops both backends; here it just empties our store.
    monkeypatch.setattr(
        main.ytmusic_service, "clear_session", lambda: store.__setitem__("headers", None)
    )

    assert main.ytmusic_service.is_signed_in()

    resp = client.get(DATA_ENDPOINT, headers={"X-Sonore-Token": api_token})
    assert resp.status_code == 401, resp.text
    assert not main.ytmusic_service.is_signed_in(), "session must be cleared on expiry"

    # A subsequent call is still refused: there is no session to fall back to.
    resp2 = client.get(DATA_ENDPOINT, headers={"X-Sonore-Token": api_token})
    assert resp2.status_code == 401, resp2.text


# -------------------------------------------------------------- yt-dlp updates


def _stub_update(monkeypatch, ok=True, version="2026.10.18", error=None):
    """Replace _fetch_yt_dlp_update so no network is needed."""
    def fake(dest_dir):
        if not ok:
            raise RuntimeError(error or "update server unreachable")
        os.makedirs(dest_dir, exist_ok=True)
        binary = os.path.join(dest_dir, "yt-dlp.exe")
        with open(binary, "w", encoding="utf-8") as f:
            f.write("stub")
        monkeypatch.setattr(main, "_YT_DLP", binary)
        return version

    monkeypatch.setattr(main, "_fetch_yt_dlp_update", fake)


def _wait_for_update_state(predicate, seconds=8.0):
    deadline = time.monotonic() + seconds
    state = {}
    while time.monotonic() < deadline:
        state = main._read_update_state()
        if predicate(state):
            return state
        time.sleep(0.05)
    return state


def test_yt_dlp_update_success(client, api_token, monkeypatch, tmp_path):
    """A successful on-demand update records ok + version and swaps the binary."""
    bin_dir = tmp_path / "sonore" / "bin"
    monkeypatch.setattr(main, "_YT_DLP_DIR", str(bin_dir))
    _stub_update(monkeypatch, ok=True, version="2026.10.18")

    resp = client.post(
        "/playback/engine/update",
        headers={"X-Sonore-Token": api_token},
    )
    assert resp.status_code == 202, resp.text
    assert resp.json()["update"] == "started"

    state = _wait_for_update_state(lambda s: s.get("ok") is True)
    assert state.get("ok") is True, state
    assert state.get("version") == "2026.10.18", state
    assert (bin_dir / "yt-dlp.exe").exists(), "the binary must be written"


def test_yt_dlp_update_failure_records_the_error(client, api_token, monkeypatch, tmp_path):
    """A failed update records ok=False, the reason, and leaves no binary."""
    bin_dir = tmp_path / "sonore" / "bin"
    monkeypatch.setattr(main, "_YT_DLP_DIR", str(bin_dir))
    _stub_update(monkeypatch, ok=False, error="network down")

    resp = client.post(
        "/playback/engine/update",
        headers={"X-Sonore-Token": api_token},
    )
    assert resp.status_code == 202, resp.text

    state = _wait_for_update_state(lambda s: s.get("ok") is False)
    assert state.get("ok") is False, state
    assert "network" in str(state.get("error", "")).lower(), state
    assert not (bin_dir / "yt-dlp.exe").exists()


def test_yt_dlp_update_rejects_missing_token(client):
    """The update endpoint is locked like every other account/data endpoint."""
    resp = client.post("/playback/engine/update")
    assert resp.status_code == 401, resp.text


def test_playback_engine_reports_version_and_source(client, api_token):
    """/playback/engine returns the version, the source and the update state."""
    resp = client.get("/playback/engine", headers={"X-Sonore-Token": api_token})
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert "version" in body
    assert "source" in body
    assert body["source"] in ("bundled", "path", "updated")
    assert "update" in body


# ------------------------------------------------------------------ port file


def test_drop_stale_port_file_removes_a_leftover_file():
    """A port file from a run that has ended is removed before we publish ours."""
    stale = pathlib.Path(main.PORT_FILE)
    stale.parent.mkdir(parents=True, exist_ok=True)
    stale.write_text("8123", encoding="utf-8")

    main._drop_stale_port_file()

    assert not stale.exists()


def test_drop_stale_port_file_is_safe_when_absent():
    """With nothing to remove the call is a no-op and must not raise."""
    pathlib.Path(main.PORT_FILE).unlink(missing_ok=True)

    main._drop_stale_port_file()

    assert not pathlib.Path(main.PORT_FILE).exists()


# ------------------------------------------------------------- yt-dlp lookup


def test_resolve_yt_dlp_prefers_the_updated_copy(tmp_path, monkeypatch):
    """An in-place update outranks the bundled binary."""
    updated = tmp_path / "bin" / "yt-dlp.exe"
    updated.parent.mkdir(parents=True, exist_ok=True)
    updated.write_text("x", encoding="utf-8")
    bundled = tmp_path / "yt-dlp.exe"
    bundled.write_text("x", encoding="utf-8")
    monkeypatch.setattr(main, "_YT_DLP_UPDATED", str(updated))
    monkeypatch.setattr(main, "_YT_DLP_BUNDLED", str(bundled))

    assert main._resolve_yt_dlp() == str(updated)


def test_resolve_yt_dlp_uses_the_bundled_copy_before_path(tmp_path, monkeypatch):
    """With no updated copy the one beside the app wins over PATH.

    The sidecar's working directory is backend\, so the installer's yt-dlp.exe
    one level up is never on PATH and must be found explicitly.
    """
    bundled = tmp_path / "yt-dlp.exe"
    bundled.write_text("x", encoding="utf-8")
    monkeypatch.setattr(main, "_YT_DLP_UPDATED", str(tmp_path / "bin" / "yt-dlp.exe"))
    monkeypatch.setattr(main, "_YT_DLP_BUNDLED", str(bundled))

    assert main._resolve_yt_dlp() == str(bundled)

