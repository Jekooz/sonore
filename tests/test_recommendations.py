"""
Automated coverage for the recommendation engine (task 6).

These tests drive the REAL FastAPI app through TestClient — the same routes
the desktop app calls — with the YouTube Music provider substituted by a
controlled fake (ytmusic_service.call), so nothing here touches a real
account or the stored session.

Covered:
  * radio candidate retrieval + parsing (get_watch_playlist / get_song_related)
  * related-shelf identifier handling
  * empty and malformed provider results
  * candidate deduplication and deterministic ranking
  * cold-start behaviour with no listening history
  * listening-event persistence, aggregation, caps, corrupt files
  * genuine rating endpoint validation + error handling (rate_song)
  * API request validation (ids, limits, exclude lists)
  * provider/network failures and auth-sensitive 401s (no real credentials)
"""

import json
import os
import sys
import threading
import time

import pytest
from fastapi.testclient import TestClient

BACKEND_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "backend"
)
if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)

import main  # noqa: E402
from services import ranking, recommend  # noqa: E402
from services import listening as listening_mod  # noqa: E402
from services.ytmusic_client import AuthError  # noqa: E402
from test_auth_capture import TEST_PORT, isolated_env  # noqa: F401  (fixture)

pytestmark = pytest.mark.usefixtures("isolated_env")


VALID_ID = "dQw4w9WgXcQ"        # 11 chars, valid alphabet
OTHER_ID = "jNQXAC9IVRw"
THIRD_ID = "M7lc1UVf-VE"


@pytest.fixture(autouse=True)
def isolated(tmp_path, monkeypatch):
    """Redirect persistent state out of the repo/machine; reset caches."""
    store = listening_mod.ListeningStore(str(tmp_path / "listening_history.json"))
    monkeypatch.setattr(main, "listening_store", store)
    monkeypatch.setattr(listening_mod, "listening_store", store)
    recommend.clear_caches()
    yield
    recommend.clear_caches()


@pytest.fixture
def client():
    # Loopback base_url + the per-install token, so these tests exercise the
    # ranking/route behaviour rather than re-testing the lockdown gate.
    tc = TestClient(main.app, base_url=f"http://127.0.0.1:{TEST_PORT}")
    tc.headers["X-Sonore-Token"] = tc.get("/auth/install-token").json()["install_token"]
    return tc


# ---------------------------------------------------------------- fakes

def watch_response(tracks, related=None):
    return {"tracks": tracks, "playlistId": "RDAMVM" + VALID_ID,
            "lyrics": None, "related": related}


def watch_track(video_id, title="Song", length="3:07"):
    return {
        "videoId": video_id,
        "title": title,
        "length": length,
        "thumbnail": [{"url": "https://img/xw60", "width": 60, "height": 60}],
        "artists": [{"name": "Artist", "id": "UC123"}],
        "album": {"name": "Album", "id": "MPREb_1"},
        "likeStatus": "INDIFFERENT",
        "inLibrary": False,
    }


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
        return self.responses[method]


def install(monkeypatch, provider):
    monkeypatch.setattr(main.ytmusic_service, "call", provider)
    return provider


# ------------------------------------------------------- /radio retrieval

def test_radio_returns_real_watch_playlist_candidates(client, monkeypatch):
    provider = install(monkeypatch, FakeProvider({
        "get_watch_playlist": watch_response([
            watch_track(VALID_ID, "Seed"),
            watch_track(OTHER_ID, "Radio pick"),
        ]),
    }))
    resp = client.get("/radio", params={"videoId": VALID_ID, "limit": 10})
    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert data["source"] == "radio"
    # The seed is deliberately excluded (test_radio_seed_is_excluded_from_results):
    # the user just played it, so it must not come back as a "new" candidate. Only
    # the OTHER_ID radio pick remains.
    assert [t["videoId"] for t in data["tracks"]] == [OTHER_ID]

    method, kwargs = provider.calls[0]
    assert method == "get_watch_playlist"
    assert kwargs["videoId"] == VALID_ID   # the seed IS the radio seed
    assert kwargs["radio"] is True, "Start Radio must use the real radio endpoint"

    # Normalized track shape the C# Track DTO deserializes (the only remaining
    # candidate is the radio pick at index 0 — the seed is excluded).
    track = data["tracks"][0]
    assert track["title"] == "Radio pick"
    assert track["artists"][0]["name"] == "Artist"
    assert track["album"]["name"] == "Album"
    assert track["duration"] == "3:07"
    assert track["durationSeconds"] == 187
    assert track["thumbnails"][0]["url"].startswith("https://img/")
    assert track["source"] == "radio"


def test_radio_seed_is_excluded_from_results(client, monkeypatch):
    install(monkeypatch, FakeProvider({
        "get_watch_playlist": watch_response([watch_track(VALID_ID), watch_track(OTHER_ID)]),
    }))
    resp = client.get("/radio", params={"videoId": VALID_ID})
    ids = [t["videoId"] for t in resp.json()["tracks"]]
    assert VALID_ID not in ids, "the seed must not recommend itself back"
    assert OTHER_ID in ids


def test_radio_empty_provider_result_is_a_clean_success(client, monkeypatch):
    install(monkeypatch, FakeProvider({"get_watch_playlist": {"tracks": []}}))
    resp = client.get("/radio", params={"videoId": VALID_ID})
    assert resp.status_code == 200, resp.text
    assert resp.json()["tracks"] == []


def test_radio_malformed_tracks_are_skipped_not_fatal(client, monkeypatch):
    install(monkeypatch, FakeProvider({
        "get_watch_playlist": watch_response([
            None, "junk", {"title": "no videoId"},
            {"videoId": 12345},           # wrong type
            watch_track(THIRD_ID),
        ]),
    }))
    resp = client.get("/radio", params={"videoId": VALID_ID})
    assert resp.status_code == 200, resp.text
    assert [t["videoId"] for t in resp.json()["tracks"]] == [THIRD_ID]


def test_radio_provider_auth_error_maps_to_401(client, monkeypatch):
    install(monkeypatch, FakeProvider(error=AuthError("Not signed in.")))
    resp = client.get("/radio", params={"videoId": VALID_ID})
    assert resp.status_code == 401
    # The backend surfaces the provider's own AuthError text verbatim
    # (main.py raises HTTPException(401, detail=str(e)) in _ranked_candidates).
    assert "signed in" in resp.json()["detail"].lower()


def test_radio_provider_failure_maps_to_502_with_sanitized_detail(client, monkeypatch):
    """Audit finding 6: the 502 detail must stay generic — upstream exception
    text ("boom" here, real YouTube JSON in production) leaks server internals
    to any local client. The full error lives in the server log only."""
    install(monkeypatch, FakeProvider(error=RuntimeError("boom")))
    resp = client.get("/radio", params={"videoId": VALID_ID})
    assert resp.status_code == 502
    detail = resp.json()["detail"]
    # Generic but actionable for the user; nothing from the exception itself.
    assert "Try again" in detail, detail
    assert "boom" not in resp.text, "upstream exception text must not reach the client"
    assert "cookie" not in resp.text.lower()


# ---------------------------------------------- related-shelf handling

def test_related_shelf_songs_are_appended_and_deduplicated(client, monkeypatch):
    provider = install(monkeypatch, FakeProvider({
        "get_watch_playlist": watch_response(
            [watch_track(VALID_ID), watch_track(OTHER_ID)],
            related="relatedbrowse1",
        ),
        "get_song_related": [
            {"title": "You might also like", "contents": [
                {"title": "Related A", "videoId": "AAAAAAAAAAA",
                 "artists": [{"name": "R", "id": None}],
                 "thumbnails": [{"url": "https://img/a", "width": 60, "height": 60}]},
                {"title": "Related dup", "videoId": OTHER_ID},      # dup of radio pick
                {"title": "Not a song", "playlistId": "RDCLAK5uy_x"},  # no videoId
            ]},
            {"title": "Recommended playlists", "contents": [
                {"title": "Mix", "playlistId": "RDCLAK5uy_y"},
            ]},
        ],
    }))
    resp = client.get("/radio", params={"videoId": VALID_ID})
    assert resp.status_code == 200, resp.text
    ids = [t["videoId"] for t in resp.json()["tracks"]]
    assert ids == [OTHER_ID, "AAAAAAAAAAA"], "radio first, related after, deduped"
    assert ("get_song_related", {"browseId": "relatedbrowse1"}) in provider.calls


def test_related_failure_still_returns_radio(client, monkeypatch):
    install(monkeypatch, FakeProvider({
        "get_watch_playlist": watch_response(
            [watch_track(VALID_ID), watch_track(OTHER_ID)], related="rb1"),
        "get_song_related": RuntimeError("related down"),   # returned, not raised
    }))
    resp = client.get("/radio", params={"videoId": VALID_ID})
    assert resp.status_code == 200, resp.text
    assert [t["videoId"] for t in resp.json()["tracks"]] == [OTHER_ID]


# ------------------------------------------------ /recommendations

def test_recommendations_exclude_list_and_limit(client, monkeypatch):
    install(monkeypatch, FakeProvider({
        "get_watch_playlist": watch_response([
            watch_track(VALID_ID), watch_track(OTHER_ID), watch_track(THIRD_ID),
        ]),
    }))
    resp = client.get("/recommendations", params={
        "seed": VALID_ID, "limit": 5, "exclude": OTHER_ID,
    })
    assert resp.status_code == 200, resp.text
    ids = [t["videoId"] for t in resp.json()["tracks"]]
    assert OTHER_ID not in ids and VALID_ID not in ids
    assert THIRD_ID in ids
    assert resp.json()["source"] == "recommendations"


def test_recommendations_rejects_bad_exclude_lists(client, monkeypatch):
    install(monkeypatch, FakeProvider({"get_watch_playlist": watch_response([])}))

    resp = client.get("/recommendations", params={
        "seed": VALID_ID, "exclude": "ok-id-123,!!!bad!!!"})
    assert resp.status_code == 400, resp.text

    resp = client.get("/recommendations", params={
        "seed": VALID_ID, "exclude": ",".join(f"id{i:09d}"[:11] for i in range(201))})
    assert resp.status_code == 400
    assert "too many" in resp.json()["detail"].lower()


@pytest.mark.parametrize("params,expected", [
    ({"videoId": "short"}, 400),                 # invalid id
    ({"videoId": VALID_ID, "limit": 0}, 422),    # bounds
    ({"videoId": VALID_ID, "limit": 999}, 422),
    ({"videoId": VALID_ID, "limit": -3}, 422),
])
def test_radio_request_validation(client, monkeypatch, params, expected):
    install(monkeypatch, FakeProvider({"get_watch_playlist": watch_response([])}))
    resp = client.get("/radio", params=params)
    assert resp.status_code == expected, resp.text


# ------------------------------------------- ranking (pure functions)

def _cand(video_id, artist="Artist", idx=0):
    return {"videoId": video_id, "title": video_id, "artists": [{"name": artist}],
            "source": "radio"}


def test_rank_preserves_provider_order_on_cold_start():
    cands = [_cand(f"cold{i:06d}abc") for i in range(6)]
    ranked = ranking.rank(cands, stats={}, familiarity={}, limit=6, exclude=set())
    assert [c["videoId"] for c in ranked] == [c["videoId"] for c in cands]


def test_rank_deduplicates_and_is_deterministic():
    cands = [_cand(VALID_ID), _cand(VALID_ID), _cand(OTHER_ID), _cand(VALID_ID)]
    first = ranking.rank(cands, stats={}, limit=10)
    second = ranking.rank(cands, stats={}, limit=10)
    assert [c["videoId"] for c in first] == [VALID_ID, OTHER_ID]
    assert first == second, "same inputs must produce the same order"


def test_rank_respects_limit_and_exclusions():
    cands = [_cand(f"vid{i:09d}") for i in range(10)]
    ranked = ranking.rank(cands, stats={}, limit=4, exclude={"vid000000000"})
    assert len(ranked) == 4
    assert "vid000000000" not in [c["videoId"] for c in ranked]


def test_rank_prefers_completed_and_liked_tracks():
    """Local completions and an explicit like must beat a cold track."""
    liked, completed, cold = "like0000000", "done0000000", "new00000000"
    stats = {
        "videos": {completed: {"plays": 4, "completed": 4, "early_skips": 0}},
        "artists": {},
        "ratings": {liked: "LIKE"},
        "recent": [],
    }
    # Provider order puts all three far back so local signal can move them.
    cands = [_cand(f"filler{i:06d}") for i in range(4)]
    cands += [_cand(cold), _cand(completed, artist="A2"),
              _cand(liked, artist="A3")]
    ranked = [c["videoId"] for c in ranking.rank(cands, stats=stats, limit=10)]
    assert ranked.index(liked) < ranked.index(cold)
    assert ranked.index(completed) < ranked.index(cold)


def test_rank_excludes_explicit_dislikes_but_not_early_skips():
    disliked, skipped = "dislike00000", "skip00000000"
    stats = {
        "videos": {
            disliked: {"plays": 3, "completed": 0, "early_skips": 0},
            skipped: {"plays": 3, "completed": 0, "early_skips": 1},
        },
        "artists": {},
        "ratings": {disliked: "DISLIKE"},
        "recent": [],
    }
    ranked = [c["videoId"] for c in ranking.rank(
        [_cand(disliked), _cand(skipped), _cand(VALID_ID)], stats=stats, limit=5)]
    assert disliked not in ranked, "only an explicit DISLIKE removes a track"
    assert skipped in ranked, "a single early skip must never ban a track"


def test_rank_penalises_recently_played():
    stats = {"videos": {}, "artists": {}, "ratings": {},
             "recent": [OTHER_ID, THIRD_ID]}
    ranked = [c["videoId"] for c in ranking.rank(
        [_cand(OTHER_ID), _cand(VALID_ID), _cand(THIRD_ID)],
        stats=stats, limit=3)]
    assert ranked[0] == VALID_ID, "just-played tracks drop to the back"
    assert ranked.index(THIRD_ID) < ranked.index(OTHER_ID)


def test_rank_caps_same_artist_diversity():
    cands = [_cand(f"song{i:08d}", artist="Same") for i in range(5)]
    cands += [_cand("other0000001", artist="Other")]
    ranked = [c["videoId"] for c in ranking.rank(cands, stats={}, limit=6)]
    same = [v for v in ranked if v.startswith("song")]
    # 5 same-artist candidates, cap 3, then the dry-pool refill takes the rest
    # only after every other candidate has had its chance.
    # Compare INDEX vs INDEX: ranked.index() returns an int, so comparing it
    # against same[3] (a videoId string) raised "'<' not supported between
    # instances of 'int' and 'str'".
    assert len(same) >= 3
    assert ranked.index("other0000001") < ranked.index(same[3])


def test_rank_boosts_familiar_history_and_library():
    known, unknown = "known000000", "unknow00000"
    familiarity = {"video_plays": {unknown: 0}, "artist_plays": {},
                   "liked": {known}}
    cands = [_cand(f"mid{i:07d}", artist=f"M{i}") for i in range(3)]
    cands += [_cand(unknown, artist="U"), _cand(known, artist="K")]
    ranked = [c["videoId"] for c in ranking.rank(
        cands, stats={}, familiarity=familiarity, limit=10)]
    assert ranked.index(known) < ranked.index(unknown), \
        "a YouTube-liked track outranks an unfamiliar one"


def test_rank_empty_inputs_fail_gracefully():
    assert ranking.rank([], stats=None, familiarity=None, limit=5) == []
    assert ranking.rank([None, "junk", {}], stats={}, limit=5) == []
    assert ranking.rank([_cand(VALID_ID)], limit=0) == []


# ------------------------------------------- listening events

def test_listening_event_persists_and_aggregates(client, monkeypatch, tmp_path):
    payload = {
        "videoId": VALID_ID, "title": "T", "artist": "A", "source": "search",
        "startedAt": 1_700_000_000, "listenedSeconds": 187,
        "durationSeconds": 187, "outcome": "completed",
    }
    resp = client.post("/listening/events", json=payload)
    assert resp.status_code == 200, resp.text
    assert resp.json()["recorded"] is True

    # A second, early-skipped play of another track.
    resp = client.post("/listening/events", json={
        "videoId": OTHER_ID, "title": "T2", "artist": "B", "source": "home",
        "startedAt": 1_700_000_100, "listenedSeconds": 15,
        "durationSeconds": 200, "outcome": "skipped"})
    assert resp.status_code == 200

    # On disk (persistent across "restarts": a fresh store reads the file).
    assert os.path.exists(main.listening_store._path)
    fresh = listening_mod.ListeningStore(main.listening_store._path)
    stats = fresh.stats()
    assert stats["videos"][VALID_ID]["plays"] == 1
    assert stats["videos"][VALID_ID]["completed"] == 1
    assert stats["videos"][OTHER_ID]["early_skips"] == 1
    assert stats["recent"][0] == OTHER_ID, "newest first"
    assert stats["artists"]["A"]["completed"] == 1


def _record(client, video_id, title, artist, started_at, outcome="completed",
            listened=100, duration=100):
    resp = client.post("/listening/events", json={
        "videoId": video_id, "title": title, "artist": artist,
        "source": "library", "startedAt": started_at,
        "listenedSeconds": listened, "durationSeconds": duration,
        "outcome": outcome,
    })
    assert resp.status_code == 200, resp.text


def test_listening_history_is_newest_first_and_one_row_per_track(client):
    _record(client, VALID_ID, "First", "Artist A", 1_700_000_000)
    _record(client, OTHER_ID, "Second", "Artist B", 1_700_000_100)
    # Replaying the first one later must not create a second row.
    _record(client, VALID_ID, "First", "Artist A", 1_700_000_200,
            outcome="skipped", listened=20)

    body = client.get("/listening/history").json()
    assert body["count"] == 2
    entries = body["entries"]
    assert [e["videoId"] for e in entries] == [VALID_ID, OTHER_ID], \
        "most recent first"
    assert entries[0]["plays"] == 2
    assert entries[0]["title"] == "First"
    assert entries[0]["artist"] == "Artist A"
    assert entries[0]["lastOutcome"] == "skipped"
    assert entries[0]["lastAt"] == 1_700_000_200


def test_listening_history_honours_its_limit(client):
    for index in range(5):
        _record(client, f"vid{index:08d}", f"T{index}", "A", 1_700_000_000 + index)

    body = client.get("/listening/history", params={"limit": 2}).json()
    assert body["count"] == 2
    assert [e["title"] for e in body["entries"]] == ["T4", "T3"]

    assert client.get("/listening/history", params={"limit": 0}).status_code == 422


def test_listening_history_is_empty_before_anything_plays(client):
    body = client.get("/listening/history").json()
    assert body == {"entries": [], "count": 0}


def test_listening_history_survives_a_restart(tmp_path):
    store = listening_mod.ListeningStore(str(tmp_path / "history.json"))
    store.record({"videoId": VALID_ID, "title": "T", "artist": "A",
                  "outcome": "completed", "startedAt": 1_700_000_000})

    reopened = listening_mod.ListeningStore(str(tmp_path / "history.json"))
    rows = reopened.recent_plays()
    assert [r["videoId"] for r in rows] == [VALID_ID]
    assert rows[0]["title"] == "T"


@pytest.mark.parametrize("body,field", [
    ({**{"videoId": VALID_ID, "outcome": "completed"}, "outcome": "meh"}, "outcome"),
    ({**{"videoId": VALID_ID, "outcome": "completed"}, "videoId": "x"}, "videoId"),
    ({**{"videoId": VALID_ID, "outcome": "completed"}, "listenedSeconds": -1}, "listenedSeconds"),
    ({**{"videoId": VALID_ID, "outcome": "completed"}, "durationSeconds": 999999}, "durationSeconds"),
    ({"videoId": VALID_ID}, "outcome"),   # missing outcome
])
def test_listening_event_validation(client, body, field):
    resp = client.post("/listening/events", json=body)
    assert resp.status_code == 422, resp.text
    assert field in resp.text


def test_listening_store_corrupt_file_resets_without_crashing(tmp_path):
    path = tmp_path / "history.json"
    path.write_text("{not json !!!", encoding="utf-8")
    store = listening_mod.ListeningStore(str(path))
    assert store.stats()["videos"] == {}
    n = store.record({"videoId": VALID_ID, "outcome": "completed",
                      "listenedSeconds": 10, "durationSeconds": 10})
    assert n == 1
    assert os.path.exists(str(path) + ".corrupt"), "bad file kept aside once"


def test_listening_store_caps_growth(tmp_path, monkeypatch):
    monkeypatch.setattr(listening_mod, "MAX_EVENTS", 5)
    store = listening_mod.ListeningStore(str(tmp_path / "cap.json"))
    for i in range(10):
        store.record({"videoId": f"vid{i:09d}", "outcome": "stopped",
                      "listenedSeconds": 1, "durationSeconds": 2})
    assert store.event_count == 5
    # Oldest dropped first: the newest event survives.
    assert store.stats()["recent"][0] == "vid000000009"


def test_listening_store_rating_memory(tmp_path):
    store = listening_mod.ListeningStore(str(tmp_path / "rates.json"))
    store.set_rating(VALID_ID, "LIKE")
    store.set_rating(OTHER_ID, "DISLIKE")
    assert store.stats()["ratings"] == {VALID_ID: "LIKE", OTHER_ID: "DISLIKE"}
    store.set_rating(VALID_ID, "INDIFFERENT")
    assert VALID_ID not in store.stats()["ratings"]
    # Persisted: a fresh reader sees it too.
    fresh = listening_mod.ListeningStore(str(tmp_path / "rates.json"))
    assert fresh.stats()["ratings"][OTHER_ID] == "DISLIKE"


def test_listening_store_rejects_bad_events(tmp_path):
    store = listening_mod.ListeningStore(str(tmp_path / "bad.json"))
    with pytest.raises(ValueError):
        store.record({"videoId": "", "outcome": "completed"})
    with pytest.raises(ValueError):
        store.record({"videoId": VALID_ID, "outcome": "sometimes"})


# ----------------------------------------------- ratings endpoint

def test_rating_success_calls_rate_song_and_remembers(client, monkeypatch):
    provider = install(monkeypatch, FakeProvider({"rate_song": {"status": "ok"}}))
    resp = client.post("/ratings", json={"videoId": VALID_ID, "rating": "LIKE"})
    assert resp.status_code == 200, resp.text
    assert resp.json() == {"videoId": VALID_ID, "rating": "LIKE", "ok": True}

    assert provider.calls == [("rate_song",
                               {"videoId": VALID_ID, "rating": "LIKE"})]
    assert main.listening_store.stats()["ratings"][VALID_ID] == "LIKE"


def test_rating_dislike_and_remove_rating(client, monkeypatch):
    provider = install(monkeypatch, FakeProvider({"rate_song": None}))
    assert client.post("/ratings",
                       json={"videoId": OTHER_ID, "rating": "DISLIKE"}).status_code == 200
    assert client.post("/ratings",
                       json={"videoId": OTHER_ID, "rating": "INDIFFERENT"}).status_code == 200
    assert OTHER_ID not in main.listening_store.stats()["ratings"]
    assert [k[1]["rating"] for k in provider.calls] == ["DISLIKE", "INDIFFERENT"]


@pytest.mark.parametrize("body", [
    {"videoId": "bad id!", "rating": "LIKE"},
    {"videoId": VALID_ID, "rating": "MAYBE"},
    {"videoId": VALID_ID},                 # missing rating
    {"rating": "LIKE"},                    # missing id
])
def test_rating_request_validation(client, body):
    resp = client.post("/ratings", json=body)
    assert resp.status_code == 422, resp.text


def test_rating_provider_auth_error_is_401(client, monkeypatch):
    install(monkeypatch, FakeProvider(error=AuthError("Session expired.")))
    resp = client.post("/ratings", json={"videoId": VALID_ID, "rating": "LIKE"})
    assert resp.status_code == 401
    assert "session" in resp.json()["detail"].lower()
    assert VALID_ID not in main.listening_store.stats()["ratings"], \
        "a rejected rating must not be remembered as applied"


def test_rating_provider_failure_is_502(client, monkeypatch):
    """Audit finding 6: the 502 detail must stay generic — the exception text
    stays in the server log, never in the HTTP response."""
    install(monkeypatch, FakeProvider(error=RuntimeError("upstream 500")))
    resp = client.post("/ratings", json={"videoId": VALID_ID, "rating": "LIKE"})
    assert resp.status_code == 502
    detail = resp.json()["detail"]
    assert "Try again" in detail, detail
    assert "upstream 500" not in resp.text, "upstream exception text must not reach the client"


# -------------------------------------------- provider familiarity

def test_provider_familiarity_uses_history_and_liked_songs(monkeypatch):
    provider = install(monkeypatch, FakeProvider({
        "get_history": [
            {"videoId": VALID_ID, "artists": [{"name": "Alpha"}]},
            {"videoId": VALID_ID, "artists": [{"name": "Alpha"}]},
            {"videoId": OTHER_ID, "artists": [{"name": "Beta"}]},
        ],
        "get_liked_songs": {"tracks": [{"videoId": THIRD_ID}]},
    }))
    fam = recommend.provider_familiarity(provider)
    assert fam["video_plays"][VALID_ID] == 2
    assert fam["artist_plays"]["Alpha"] == 2
    assert THIRD_ID in fam["liked"]


def test_provider_familiarity_survives_provider_failure(monkeypatch):
    provider = install(monkeypatch, FakeProvider(error=RuntimeError("offline")))
    fam = recommend.provider_familiarity(provider)
    assert fam == {"video_plays": {}, "artist_plays": {}, "liked": set()}


def test_search_filter_still_validated(client, monkeypatch):
    """Existing endpoint: unknown category must stay a clean 400."""
    monkeypatch.setattr(main.ytmusic_service, "call",
                        FakeProvider({"search": []}))
    resp = client.get("/search", params={"q": "oasis", "filter": "unicorns"})
    assert resp.status_code == 400
    assert "unicorns" in resp.json()["detail"]


# ------------------------------------------------ stream prefetch (P2)

def test_prefetch_invalid_id_rejected(client):
    resp = client.get("/prefetch/not\x20an-id!")
    assert resp.status_code == 400, resp.text


def test_prefetch_returns_started_then_caches(client, monkeypatch):
    """The prefetch endpoint warms the SAME cache /stream reads: after the
    background warm completes, /stream must answer from the cache with the
    exact URL the warm-up resolved (no second resolve round-trip).

    The definitive cache-witness is /stream (same cache), NOT /prefetch's own
    status: while /prefetch is idle-unlocked it may legitimately fire a NEW
    warm-up (202 'started') once the cache check races a delayed write — asserting
    on it made this test flaky. /stream 200 + exact URL is unambiguous."""
    main._STREAM_CACHE.clear()
    parallel = threading.Event()

    def slow_resolve(vid):
        parallel.wait(timeout=5)   # hold the warm-up in flight deterministically
        return "https://cdn.example/audio"

    monkeypatch.setattr(main, "_resolve_stream", slow_resolve)
    try:
        # 1st call starts the warm-up (202); a second call while it is busy is
        # skipped rather than queued (bounded: one warm at a time).
        t0 = time.perf_counter()
        r_start = client.get("/prefetch/WARMID12345")
        elapsed_202 = time.perf_counter() - t0
        assert r_start.status_code == 202, r_start.text
        assert r_start.json()["warmed"] == "started"
        assert elapsed_202 < 0.3, "202 must return immediately, not wait for the resolve"

        r_busy = client.get("/prefetch/WARMID12345")
        if r_busy.status_code == 202:   # still warming
            assert r_busy.json()["warmed"] == "skipped-busy"

        # Release the warm-up and wait until the cache has landed, witnessed by
        # /stream serving the warmed URL without invoking the slow resolver again.
        parallel.set()
        deadline = time.time() + 5
        resp = client.get("/stream/WARMID12345")
        while (resp.status_code != 200 or resp.json().get("url") != "https://cdn.example/audio") and time.time() < deadline:
            time.sleep(0.05)
            resp = client.get("/stream/WARMID12345")
        assert resp.status_code == 200, resp.text
        assert resp.json()["url"] == "https://cdn.example/audio"
    finally:
        parallel.set()
        main._STREAM_CACHE.clear()



def test_stream_still_validates_ids(client, monkeypatch):
    """The /stream endpoint keeps its 400 on a malformed id — prefetch must not
    have opened a validation bypass."""
    resp = client.get("/stream/bad id!")
    assert resp.status_code == 400
