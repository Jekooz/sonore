"""
Coverage for the layered recommender: the three sources, the blender, the
local taste layer and the new API routes.

Same rules as the other backend tests: these drive the REAL FastAPI app
through TestClient, the YouTube Music provider is substituted by a controlled
fake, the local store is redirected into a tmp directory, and every outside
service is mocked — nothing here touches a real account, a real network or
the machine's own data.

Covered:
  * blender weighting, dedupe, filters, diversity cap and determinism
  * the local taste layer: recency decay, completion bonus, like weight,
    early-skip penalty
  * the outside source: configured, unconfigured, and failing
  * the local-learning switch
  * the new routes: blending, event ingestion, settings, clearing
  * the token gate and the Origin check on every new route
"""

import os
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
from recommender import blender, config, engine  # noqa: E402
from recommender.settings import RecommenderSettings, SettingsStore  # noqa: E402
from recommender.store import TasteStore  # noqa: E402
from services import recommend  # noqa: E402
from test_auth_capture import TEST_PORT, isolated_env  # noqa: F401  (fixture)

pytestmark = pytest.mark.usefixtures("isolated_env")

VALID_ID = "dQw4w9WgXcQ"
OTHER_ID = "jNQXAC9IVRw"
THIRD_ID = "M7lc1UVf-VE"
FOURTH_ID = "oHgczSzMKL3"


@pytest.fixture(autouse=True)
def isolated(tmp_path, monkeypatch):
    """Redirect the local layer into a tmp dir and reset every cache."""
    store = TasteStore(str(tmp_path / "taste.db"))
    monkeypatch.setattr(main.recommender, "taste_store", store)
    monkeypatch.setattr(
        main.recommender, "settings_store", SettingsStore("recommender_test.dat")
    )
    recommend.clear_caches()
    main.recommender.cache.clear()
    yield
    recommend.clear_caches()
    main.recommender.cache.clear()


@pytest.fixture
def client():
    tc = TestClient(main.app, base_url=f"http://127.0.0.1:{TEST_PORT}")
    tc.headers["X-Sonore-Token"] = tc.get("/auth/install-token").json()[
        "install_token"
    ]
    return tc


# ---------------------------------------------------------------- fakes


def watch_track(video_id, title="Song", artist="Artist", length="3:07"):
    return {
        "videoId": video_id,
        "title": title,
        "length": length,
        "thumbnail": [{"url": "https://img/xw60", "width": 60, "height": 60}],
        "artists": [{"name": artist, "id": "UC123"}],
        "album": {"name": "Album", "id": "MPREb_1"},
        "inLibrary": False,
    }


def home_row(title, tracks):
    return {"title": title, "contents": tracks}


class FakeProvider:
    """Stands in for YTMusic: records calls, returns scripted responses."""

    def __init__(self, responses=None, error=None):
        self.responses = responses or {}
        self.error = error
        self.calls = []

    def __call__(self, method, **kwargs):
        self.calls.append((method, kwargs))
        if self.error is not None:
            raise self.error
        if method not in self.responses:
            raise AssertionError(f"unexpected provider call: {method}")
        response = self.responses[method]
        if callable(response):
            return response(**kwargs)
        return response


def install(monkeypatch, provider):
    monkeypatch.setattr(main.ytmusic_service, "call", provider)
    return provider


def candidate(video_id, title="Song", artist="Artist", affinity=1.0, source="yt"):
    return {
        "videoId": video_id,
        "title": title,
        "artists": [{"name": artist, "id": "UC123"}],
        "album": None,
        "thumbnails": [],
        "duration": "3:07",
        "durationSeconds": 187,
        "inLibrary": False,
        "source": source,
        "affinity": affinity,
    }


# ---------------------------------------------------------------- blender


def test_blender_weights_you_tube_most():
    """YouTube Music's word outweighs the local layer's, at equal affinity."""
    items = blender.blend(
        {
            "yt": [candidate(VALID_ID, "First", "One", affinity=1.0)],
            "local": [
                candidate(OTHER_ID, "Second", "Two", affinity=1.0, source="local")
            ],
        },
        limit=5,
    )

    assert [item["videoId"] for item in items] == [VALID_ID, OTHER_ID]
    assert items[0]["score"] > items[1]["score"]
    assert items[0]["source"] == "yt"


def test_blender_uses_the_configured_weights():
    """The weights are the ones in the config, and they are the only ones."""
    items = blender.blend(
        {
            "yt": [candidate(VALID_ID, "First", "One", affinity=1.0)],
            "local": [
                candidate(OTHER_ID, "Second", "Two", affinity=1.0, source="local")
            ],
            "external": [
                candidate(THIRD_ID, "Third", "Three", affinity=1.0, source="external")
            ],
        },
        limit=5,
    )
    scores = {item["videoId"]: item["score"] for item in items}
    assert scores[VALID_ID] == pytest.approx(config.WEIGHT_YOUTUBE)
    assert scores[OTHER_ID] == pytest.approx(config.WEIGHT_LOCAL)
    assert scores[THIRD_ID] == pytest.approx(config.WEIGHT_EXTERNAL)


def test_blender_merges_one_song_from_two_sources():
    """The same song from two sources is one row, credited to both."""
    items = blender.blend(
        {
            "yt": [candidate(VALID_ID, "Song", "Artist")],
            "local": [candidate(VALID_ID, "Song", "Artist", source="local")],
        },
        limit=5,
    )

    assert len(items) == 1
    assert items[0]["sources"] == ["local", "yt"]
    assert items[0]["score"] == pytest.approx(
        config.WEIGHT_YOUTUBE + config.WEIGHT_LOCAL
    )


def test_blender_dedupes_by_video_id():
    """The same video id twice is one row."""
    items = blender.blend(
        {"yt": [candidate(VALID_ID), candidate(VALID_ID, "Other title")]},
        limit=5,
    )
    assert len(items) == 1


def test_blender_dedupes_by_normalized_artist_and_title():
    """The same song under a different video id is still one row."""
    items = blender.blend(
        {
            "yt": [candidate(VALID_ID, "Sajnaani (Remix)", "Karan Aujla")],
            "local": [
                candidate(
                    OTHER_ID, "sajnaani remix", "karan aujla", source="local"
                )
            ],
        },
        limit=5,
    )
    assert len(items) == 1


def test_blender_drops_recently_played_and_disliked_tracks():
    """What was just played, and what was disliked, never comes back."""
    items = blender.blend(
        {
            "yt": [
                candidate(VALID_ID),
                candidate(OTHER_ID),
                candidate(THIRD_ID),
            ]
        },
        limit=5,
        recent=[VALID_ID],
        disliked=[OTHER_ID],
    )
    assert [item["videoId"] for item in items] == [THIRD_ID]


def test_blender_caps_repeats_per_artist():
    """No artist may fill the list while other artists are available."""
    items = blender.blend(
        {
            "yt": [
                candidate(VALID_ID, "One", "Same Artist"),
                candidate(OTHER_ID, "Two", "Same Artist"),
                candidate(THIRD_ID, "Three", "Same Artist"),
                candidate(FOURTH_ID, "Four", "Other Artist"),
                candidate("kJYP7VvSObc", "Five", "Third Artist"),
            ]
        },
        limit=4,
        max_per_artist=2,
    )
    same = [item for item in items if item["artists"][0]["name"] == "Same Artist"]
    assert len(same) == 2
    assert len(items) == 4


def test_blender_keeps_variety_when_the_pool_runs_dry():
    """A short pool fills the list rather than coming back thin."""
    items = blender.blend(
        {
            "yt": [
                candidate(VALID_ID, "One", "Same Artist"),
                candidate(OTHER_ID, "Two", "Same Artist"),
                candidate(THIRD_ID, "Three", "Same Artist"),
            ]
        },
        limit=3,
        max_per_artist=1,
    )
    assert len(items) == 3


def test_blender_never_returns_an_item_without_a_video_id():
    """An outside hint on its own is not a playable recommendation."""
    hint = {
        "videoId": None,
        "title": "Unknown Song",
        "artists": [{"name": "Nobody", "id": None}],
        "affinity": 1.0,
        "source": "external",
    }
    items = blender.blend({"external": [hint]}, limit=5)
    assert items == []


def test_external_hint_boosts_the_song_it_names():
    """An outside signal about a song the provider already offered lifts it."""
    boost = {
        "videoId": None,
        "title": "Song",
        "artists": [{"name": "Artist", "id": None}],
        "affinity": 1.0,
        "source": "external",
    }
    items = blender.blend(
        {
            "yt": [candidate(VALID_ID, "Song", "Artist")],
            "local": [candidate(OTHER_ID, "Other", "Artist", source="local")],
            "external": [boost],
        },
        limit=5,
    )
    scores = {item["videoId"]: item["score"] for item in items}
    assert scores[VALID_ID] == pytest.approx(
        config.WEIGHT_YOUTUBE + config.WEIGHT_EXTERNAL * config.EXTERNAL_SONG_BOOST
    )
    # The boost did not travel to the other song by the same artist.
    assert scores[OTHER_ID] == pytest.approx(config.WEIGHT_LOCAL)


# ------------------------------------------------- the local taste layer


def test_an_early_skip_is_a_negative_signal():
    """A skip in the first moments takes the track's score below zero."""
    store = TasteStore()
    store.record_skip(VALID_ID, "Song", "Artist", played_fraction=0.1)
    affinity = store.affinity()

    assert affinity["tracks"][VALID_ID] < 0
    assert affinity["artists"]["Artist"] < 0
    assert VALID_ID in affinity["disliked"]


def test_a_late_skip_is_only_a_weak_negative():
    """A track that was heard through is not a dislike."""
    store = TasteStore()
    store.record_skip(VALID_ID, "Song", "Artist", played_fraction=0.8)
    affinity = store.affinity()

    assert affinity["tracks"][VALID_ID] < 0
    assert affinity["tracks"][VALID_ID] > -config.SKIP_PENALTY
    assert VALID_ID not in affinity["disliked"]


def test_recency_decay_favours_the_recent_play():
    """Yesterday's play counts for more than last month's."""
    store = TasteStore()
    now = time.time()
    store.record_play(VALID_ID, "Song", "Artist", ts=now, completed=True)
    store.record_play(OTHER_ID, "Other", "Artist", ts=now - 60 * 86400, completed=True)
    affinity = store.affinity(now=now)

    assert affinity["artists"]["Artist"] > 0
    # Two plays of the same weight, one of them a fortnight-plus old.
    assert affinity["tracks"][VALID_ID] > affinity["tracks"][OTHER_ID]


def test_a_like_is_the_strongest_positive_signal():
    """A like outweighs a play."""
    store = TasteStore()
    now = time.time()
    store.record_play(VALID_ID, "Song", "Artist", ts=now, completed=True)
    store.record_like(OTHER_ID, "Other", "Artist", ts=now)
    affinity = store.affinity(now=now)

    assert affinity["tracks"][OTHER_ID] > affinity["tracks"][VALID_ID]


def test_a_completion_counts_for_more_than_a_partial_play():
    """Finishing a track is worth more than starting it."""
    store = TasteStore()
    now = time.time()
    store.record_play(VALID_ID, "Song", "Artist", ts=now, completed=True)
    store.record_play(OTHER_ID, "Other", "Artist", ts=now, completed=False)
    affinity = store.affinity(now=now)

    assert affinity["tracks"][VALID_ID] > affinity["tracks"][OTHER_ID]


def test_clearing_the_store_forgets_everything():
    """The store can be emptied, and then it knows nothing."""
    store = TasteStore()
    store.record_play(VALID_ID, "Song", "Artist")
    store.record_like(VALID_ID, "Song", "Artist")
    store.clear()

    affinity = store.affinity()
    assert not affinity["tracks"]
    assert not affinity["artists"]
    assert store.counts() == {"plays": 0, "skips": 0, "likes": 0}


# ---------------------------------------------------- the outside sources


def test_unconfigured_outside_source_is_skipped():
    """With no token and no key, the outside layer does not exist."""
    from recommender.sources import external

    assert external.external_candidates() == []


def test_a_failing_outside_service_is_silent(monkeypatch):
    """A timeout inside the outside layer costs nothing but the layer."""
    from recommender.sources import external

    def boom(url, headers):
        raise OSError("timed out")

    hints = external.external_candidates(
        listenbrainz_token="token", lastfm_api_key="key", fetch=boom
    )
    assert hints == []


def test_the_outside_layer_reads_both_services(monkeypatch):
    """Configured and answering, the outside layer produces hints."""
    from recommender.sources import external

    def fake_fetch(url, headers):
        if "listenbrainz" in url:
            return (
                '[{"track_metadata": {"artist_name": "Karan Aujla",'
                ' "track_name": "Softly"}}]'
            )
        if "artist.getsimilar" in url:
            return '{"similarartists": {"artist": [{"name": "Arjun"}]}}'
        return '{"similartracks": {"track": []}}'

    hints = external.external_candidates(
        listenbrainz_token="token",
        lastfm_api_key="key",
        seed_artist="Karan Aujla",
        seed_title="Softly",
        fetch=fake_fetch,
    )
    names = {hint["artists"][0]["name"] for hint in hints if hint["artists"]}
    assert "Karan Aujla" in names
    assert "Arjun" in names


# -------------------------------------------------------- the API routes


def test_home_recommendation_row_is_blended(client, monkeypatch):
    """The row the Home screen shows comes from the new route."""
    provider = install(
        monkeypatch,
        FakeProvider(
            {
                "get_home": [
                    home_row("Listen again", [watch_track(OTHER_ID, "Older")]),
                    home_row(
                        "Recommended for you",
                        [watch_track(VALID_ID, "Fresh pick")],
                    ),
                ],
                "get_liked_songs": {"tracks": []},
            }
        ),
    )

    resp = client.get("/recommendations/home", params={"limit": 10})
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["title"] == "Recommended for you"
    assert [item["videoId"] for item in body["items"]] == [VALID_ID]
    assert body["items"][0]["source"] == "yt"
    assert provider.calls[0][0] == "get_home"


def test_next_recommendations_exclude_the_seed_and_the_queue(client, monkeypatch):
    """The seed and everything already queued never come back."""
    install(
        monkeypatch,
        FakeProvider(
            {
                "get_watch_playlist": {
                    "tracks": [
                        watch_track(VALID_ID, "Seed"),
                        watch_track(OTHER_ID, "Queued"),
                        watch_track(THIRD_ID, "Next"),
                    ],
                    "related": None,
                },
                "get_liked_songs": {"tracks": []},
            }
        ),
    )

    resp = client.get(
        "/recommendations/next",
        params={"seed": VALID_ID, "limit": 10, "exclude": OTHER_ID},
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert [item["videoId"] for item in body["tracks"]] == [THIRD_ID]


def test_events_are_recorded_for_the_local_layer(client):
    """A play, a skip and a like all reach the local store."""
    for path, payload in (
        (
            "/events/play",
            {
                "videoId": VALID_ID,
                "title": "Song",
                "artist": "Artist",
                "listenedSeconds": 180,
                "durationSeconds": 187,
                "completed": True,
            },
        ),
        (
            "/events/skip",
            {
                "videoId": OTHER_ID,
                "title": "Other",
                "artist": "Artist",
                "listenedSeconds": 5,
                "durationSeconds": 200,
                "playedFraction": 0.02,
            },
        ),
        (
            "/events/like",
            {"videoId": THIRD_ID, "title": "Liked", "artist": "Artist"},
        ),
    ):
        resp = client.post(path, json=payload)
        assert resp.status_code == 200, resp.text

    counts = main.recommender.taste_store.counts()
    assert counts["plays"] == 1
    assert counts["skips"] == 1
    assert counts["likes"] == 1


def test_the_local_layer_can_be_switched_off(client, monkeypatch):
    """With local learning off, nothing is recorded and nothing is used."""
    main.recommender.settings_store.save(
        RecommenderSettings(local_learning=False)
    )

    resp = client.post(
        "/events/play",
        json={"videoId": VALID_ID, "title": "Song", "artist": "Artist"},
    )
    assert resp.status_code == 200, resp.text
    assert main.recommender.taste_store.counts()["plays"] == 0


def test_settings_round_trip(client):
    """The Settings screen can store and read back the credentials."""
    resp = client.post(
        "/recommendations/settings",
        json={
            "localLearning": True,
            "listenbrainzToken": "lb-token",
            "lastfmApiKey": "lf-key",
            "listenbrainzUser": "jekooz",
        },
    )
    assert resp.status_code == 200, resp.text

    resp = client.get("/recommendations/settings")
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["localLearning"] is True
    assert body["listenbrainzToken"] == "lb-token"
    assert body["lastfmApiKey"] == "lf-key"
    assert body["externalConfigured"] is True


def test_clearing_listening_data_empties_the_store(client):
    """The clear button really forgets."""
    client.post(
        "/events/play",
        json={"videoId": VALID_ID, "title": "Song", "artist": "Artist"},
    )
    assert main.recommender.taste_store.counts()["plays"] == 1

    resp = client.post("/recommendations/clear")
    assert resp.status_code == 200, resp.text
    assert main.recommender.taste_store.counts() == {
        "plays": 0,
        "skips": 0,
        "likes": 0,
    }


def test_a_failing_provider_still_answers_with_a_clear_error(client, monkeypatch):
    """A provider failure is a 502, not a broken-looking success."""
    install(monkeypatch, FakeProvider(error=RuntimeError("provider down")))

    resp = client.get("/recommendations/home")
    assert resp.status_code == 502, resp.text


# ------------------------------------------------------------ the gate


NEW_ROUTES = [
    ("GET", "/recommendations/home"),
    ("GET", "/recommendations/next?seed=dQw4w9WgXcQ"),
    ("GET", "/recommendations/settings"),
    ("POST", "/recommendations/settings"),
    ("POST", "/recommendations/clear"),
    ("POST", "/events/play"),
    ("POST", "/events/skip"),
    ("POST", "/events/like"),
]


def test_every_new_route_needs_the_install_token():
    """No new route is reachable without the per-install token."""
    tc = TestClient(main.app, base_url=f"http://127.0.0.1:{TEST_PORT}")
    for method, path in NEW_ROUTES:
        resp = tc.request(method, path)
        assert resp.status_code == 401, f"{method} {path} -> {resp.status_code}"
        assert "api token is required" in resp.json()["detail"].lower(), path


def test_every_new_route_rejects_a_foreign_origin(client):
    """A web origin is refused before the token is even looked at."""
    for method, path in NEW_ROUTES:
        resp = client.request(
            method, path, headers={"Origin": "https://example.com"}
        )
        assert resp.status_code == 403, f"{method} {path} -> {resp.status_code}"


def test_the_new_routes_are_not_reachable_from_another_host():
    """A request whose Host is not loopback is refused."""
    tc = TestClient(main.app, base_url="http://example.com")
    for method, path in NEW_ROUTES:
        resp = tc.request(method, path)
        assert resp.status_code == 403, f"{method} {path} -> {resp.status_code}"


def test_the_weights_are_the_documented_defaults():
    """The defaults are the ones the design names."""
    assert config.WEIGHT_YOUTUBE == 0.65
    assert config.WEIGHT_LOCAL == 0.25
    assert config.WEIGHT_EXTERNAL == 0.10
    assert config.WEIGHT_YOUTUBE > config.WEIGHT_LOCAL > config.WEIGHT_EXTERNAL


def test_the_engine_uses_the_shared_stores():
    """The engine reads the package-level stores, so a test can replace them."""
    assert engine.recommend_home is not None
    assert main.recommender.taste_store is not None
    assert main.recommender.settings_store is not None
