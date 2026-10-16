"""
Automated coverage for the artist follow/unfollow endpoint.

The Home hero's Follow button is only honest if it performs a real account
change, so this drives the REAL FastAPI app through TestClient — the same route
the app calls — with the YouTube Music provider substituted by a controlled fake
(`ytmusic_service.call`). Nothing here touches a real account or stored session.

Covered:
  * subscribe forwards to ytmusicapi's subscribe_artist with the channel id
  * unsubscribe forwards to unsubscribe_artists with a one-element list
  * the read side (GET) still returns the provider's subscription list
  * malformed artist ids are rejected before the provider is reached
  * auth failures surface as 401 and other provider failures as 502

Access model (same as every other sidecar data route):
  * the route reaches the account only through `_data`, the shared wrapper that
    turns an AuthError into 401 — so a session-less sidecar cannot be made to
    follow or unfollow anything. The tests below assert that for BOTH
    directions, not just the subscribe case.
  * "local only" is the process, not a header: `python main.py` binds
    127.0.0.1 and the app carries no CORS middleware, so no other host can
    reach it. There is deliberately no per-route loopback check to duplicate
    here — one exists nowhere else in this file, and adding it only to this
    route would make it the one route that behaves differently.
"""

import os
import sys

import pytest
from fastapi.testclient import TestClient

BACKEND_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "backend"
)
if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)

import main  # noqa: E402
from services.ytmusic_client import AuthError  # noqa: E402


ARTIST_ID = "UC5275386193416ad3d1be2f"


@pytest.fixture
def client():
    return TestClient(main.app)


class FakeProvider:
    """Stands in for YTMusic: records calls, returns a scripted answer."""

    def __init__(self, response=None, error=None):
        self.response = response if response is not None else {}
        self.error = error
        self.calls = []

    def __call__(self, method, **kwargs):
        self.calls.append((method, kwargs))
        if self.error is not None:
            raise self.error
        return self.response


def install(monkeypatch, provider):
    monkeypatch.setattr(main.ytmusic_service, "call", provider)
    return provider


def test_following_an_artist_really_subscribes(client, monkeypatch):
    provider = install(monkeypatch, FakeProvider({"actions": []}))

    resp = client.post(
        "/library/subscriptions",
        json={"artistId": ARTIST_ID, "subscribed": True},
    )

    assert resp.status_code == 200, resp.text
    assert resp.json() == {"artistId": ARTIST_ID, "subscribed": True}
    assert provider.calls == [("subscribe_artist", {"channelId": ARTIST_ID})]


def test_unfollowing_uses_the_list_form_the_library_exposes(client, monkeypatch):
    provider = install(monkeypatch, FakeProvider({"actions": []}))

    resp = client.post(
        "/library/subscriptions",
        json={"artistId": ARTIST_ID, "subscribed": False},
    )

    assert resp.status_code == 200, resp.text
    assert resp.json() == {"artistId": ARTIST_ID, "subscribed": False}
    assert provider.calls == [
        ("unsubscribe_artists", {"channelIds": [ARTIST_ID]})
    ]


def test_the_read_side_still_lists_subscriptions(client, monkeypatch):
    install(monkeypatch, FakeProvider([{"browseId": ARTIST_ID}]))

    resp = client.get("/library/subscriptions")

    assert resp.status_code == 200, resp.text
    assert resp.json() == [{"browseId": ARTIST_ID}]


@pytest.mark.parametrize(
    "artist_id",
    ["", "short", "has spaces", "bad!chars"],
)
def test_a_malformed_artist_id_is_rejected_before_the_provider(
    client, monkeypatch, artist_id
):
    provider = install(monkeypatch, FakeProvider())

    resp = client.post(
        "/library/subscriptions",
        json={"artistId": artist_id, "subscribed": True},
    )

    assert resp.status_code == 422, resp.text
    assert provider.calls == []


def test_a_missing_session_is_a_401_not_a_500(client, monkeypatch):
    install(monkeypatch, FakeProvider(error=AuthError("Not signed in.")))

    resp = client.post(
        "/library/subscriptions",
        json={"artistId": ARTIST_ID, "subscribed": True},
    )

    assert resp.status_code == 401, resp.text
    assert resp.json()["detail"] == "Not signed in."


@pytest.mark.parametrize("subscribed", [True, False])
def test_both_directions_require_a_session(client, monkeypatch, subscribed):
    """Follow and unfollow are gated identically.

    A write that could clear a subscription without a session would be worse
    than one that only adds: this pins both directions to the shared gate.
    """
    provider = install(monkeypatch, FakeProvider(error=AuthError("Not signed in.")))

    resp = client.post(
        "/library/subscriptions",
        json={"artistId": ARTIST_ID, "subscribed": subscribed},
    )

    assert resp.status_code == 401, resp.text
    # The one provider call that was attempted is the one that raised: nothing
    # was performed against the account.
    assert provider.calls == [
        (
            "subscribe_artist" if subscribed else "unsubscribe_artists",
            (
                {"channelId": ARTIST_ID}
                if subscribed
                else {"channelIds": [ARTIST_ID]}
            ),
        )
    ]


def test_the_read_side_is_gated_by_the_same_wrapper(client, monkeypatch):
    """GET /library/subscriptions reads the account, so it is gated too."""
    install(monkeypatch, FakeProvider(error=AuthError("Not signed in.")))

    resp = client.get("/library/subscriptions")

    assert resp.status_code == 401, resp.text


def test_an_upstream_failure_is_a_retryable_502(client, monkeypatch):
    install(monkeypatch, FakeProvider(error=RuntimeError("boom")))

    resp = client.post(
        "/library/subscriptions",
        json={"artistId": ARTIST_ID, "subscribed": False},
    )

    assert resp.status_code == 502, resp.text
    assert "Try again shortly" in resp.json()["detail"]
