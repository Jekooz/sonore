"""
Record the sidecar's real responses and anonymize them for the test suite.

Why this exists
---------------
The widget and data-layer tests are only worth anything if they run against the
payload shapes the real service actually sends. But those payloads are also a
real person's library: their liked songs, playlists, listening history and
account handle. This repository is public, so committing the raw responses would
publish someone's listening data.

This tool therefore fetches the real responses from the running sidecar
(`backend/main.py`) and rewrites every value that identifies content or the
account, while preserving:

  * the exact key set and nesting of every row,
  * value *types* and formats (`duration_seconds` stays an int, `duration` stays
    "m:ss"),
  * id *prefixes* (`MPREb_`, `VL`, `UC`, `MPLAUC`, `MPSPPL`, `OLAK5uy`, `RDAM`),
    because the app routes on them,
  * the structural quirks the parsers must handle: artist rows carry `artist`
    instead of `title`, Home song cards carry both a `videoId` and a radio
    `playlistId`, some rows omit `duration_seconds`, and podcast rows have no
    playable target at all.

Substitutions are a deterministic function of the original value (SHA-1), so
regenerating produces identical output and golden images stay stable.

Usage
-----
    python tool/anonymize_fixtures.py            # uses http://127.0.0.1:8000
    YTM_BASE_URL=http://127.0.0.1:8003 python tool/anonymize_fixtures.py

Run it against a signed-in sidecar; the fixtures it writes are what
`test/data_layer_test.dart` and the widget-test harness read.
"""

import hashlib
import json
import os
import re
import sys
import urllib.request

BASE = os.environ.get("YTM_BASE_URL", "http://127.0.0.1:8000")
OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "test", "fixtures")

# Id prefixes that carry meaning for the app and must survive anonymization.
ID_PREFIXES = (
    "MPREb_", "MPLAUC", "MPSPPL", "OLAK5uy_", "RDAM", "RDEM", "RDAO",
    "VLPL", "VL", "UC", "PL", "LM",
)

# Keys whose string value identifies content or the account.
# Per-user opaque blobs. They identify the session's own state (rating and
# "listen again" pins) rather than public content, and they are large, so they
# are dropped outright instead of rewritten.
DROP_KEYS = {"feedbackTokens", "listenAgainFeedbackTokens"}

TEXT_KEYS = {
    "title": "Title",
    "subtitle": "Subtitle",   # album pages compose "<artists> · <year>"
    "artist": "Artist",
    "author": "Curator",
    "description": "Description",
    "subscribers": "Listeners",
    "views": "Plays",
    "year": None,          # left alone: a year is not identifying
    "category": None,      # UI strings like "Top result"
    "type": None,          # Album / EP / Single
    "resultType": None,
    "likeStatus": None,
    "videoType": None,
    "privacy": None,
    "episodeType": None,
    "date": "Date",
}


def digest(value: str) -> int:
    """A stable number for a value, so the same input always maps the same way."""
    return int(hashlib.sha1(value.encode("utf-8")).hexdigest()[:8], 16)


# One label per distinct original string, so relationships the service keeps are
# kept here too: an album page's title and the album name on its own tracks are
# the same string, and must stay the same string after anonymizing.
LABEL_CACHE = {}


def fake_text(kind: str, original: str) -> str:
    cached = LABEL_CACHE.get(original)
    if cached is not None:
        return cached
    label = f"{kind} {digest(original) % 900 + 100}"
    LABEL_CACHE[original] = label
    return label


def fake_id(original: str) -> str:
    """Keep the prefix, replace the body."""
    body = hashlib.sha1(original.encode("utf-8")).hexdigest()[:18]
    for prefix in sorted(ID_PREFIXES, key=len, reverse=True):
        if original.startswith(prefix):
            if prefix == "LM":
                # The liked-music playlist id is a service constant, not user data.
                return "LM"
            return prefix + body[:16]
    return body[:11]


def fake_url(original: str, width) -> str:
    return f"https://example.invalid/art/{digest(original) % 100000}-{width}.jpg"


def scrub(node, parent_key: str = ""):
    """Recursively rewrite identifying values, preserving structure and types."""
    if isinstance(node, list):
        return [scrub(item, parent_key) for item in node]
    if not isinstance(node, dict):
        return node

    out = {}
    for key, value in node.items():
        if key in DROP_KEYS:
            continue
        if key == "thumbnails" and isinstance(value, list):
            out[key] = [
                {**entry,
                 "url": fake_url(str(entry.get("url", "")), entry.get("width", 0))}
                if isinstance(entry, dict) else entry
                for entry in value
            ]
            continue

        if isinstance(value, (dict, list)):
            out[key] = scrub(value, key)
            continue

        if isinstance(value, str) and value:
            # `id` is the nested id inside artists[], an album object and a
            # podcast: it identifies content just as directly as browseId, and
            # missing it is how a real channel id leaks into a fixture.
            if key in ("videoId", "browseId", "playlistId", "audioPlaylistId",
                       "creditsBrowseId", "radioId", "shuffleId", "channelId",
                       "id"):
                out[key] = fake_id(value)
                continue
            if key == "accountName":
                out[key] = "Test Account"
                continue
            if key == "channelHandle":
                out[key] = "@test_account"
                continue
            if key == "accountPhotoUrl":
                out[key] = "https://example.invalid/avatar.jpg"
                continue
            if key == "name":
                # `name` appears for artists (inside artists[]), for an album
                # object, and for a podcast show; the parent says which.
                kind = {"artists": "Artist", "album": "Album",
                        "podcast": "Show"}.get(parent_key, "Name")
                out[key] = fake_text(kind, value)
                continue
            if key in TEXT_KEYS:
                kind = TEXT_KEYS[key]
                if kind is None:
                    out[key] = value
                elif key == "year":
                    out[key] = value
                else:
                    out[key] = fake_text(kind, value)
                continue

        out[key] = value
    return out


def get(path: str, timeout: int = 120):
    with urllib.request.urlopen(BASE + path, timeout=timeout) as response:
        return json.load(response)


WRITTEN = []


def write(name: str, payload) -> None:
    path = os.path.join(OUT_DIR, name)
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=1)
        handle.write("\n")
    WRITTEN.append((name, payload))
    print(f"  {name:24s} {os.path.getsize(path):>8,} bytes")


def self_check(name: str, payload) -> list:
    """Reports values that still look like the real service's own.

    Only two classes can be checked mechanically: URLs that are not the
    example.invalid placeholder, and bare strings shaped like a channel or
    video id. Anything else would need the original to compare against, which is
    exactly what this tool must not keep.
    """
    findings = []

    def walk(node, path):
        if isinstance(node, dict):
            for key, value in node.items():
                walk(value, f"{path}.{key}")
        elif isinstance(node, list):
            for index, value in enumerate(node):
                walk(value, f"{path}[{index}]")
        elif isinstance(node, str):
            if "//" in node and not node.startswith("https://example.invalid"):
                findings.append(f"{name}{path} carries a real URL")
            elif re.fullmatch(r"(UC|MPLAUC)[A-Za-z0-9_-]{18,}", node):
                findings.append(f"{name}{path} carries a real channel id")

    walk(payload, "")
    return findings


def record_recommendations() -> None:
    """Autoplay's refill: ranked candidates for one seed.

    The seed is a real video id from the account's own songs, so the fixture is
    what the app would actually be handed at the end of a queue.
    """
    songs = get("/library/songs")
    seed = songs[0]["videoId"]
    payload = scrub(get(f"/recommendations?seed={seed}&limit=8"))
    # The response echoes the seed, and scrub() rewrites every id it sees -- but
    # the *same* original always maps to the same replacement, so scrubbing the
    # seed gives the id this fixture actually contains. Writing the raw one here
    # would publish a real video id.
    payload["seed"] = scrub({"videoId": seed})["videoId"]
    write("recommendations.json", payload)


def main() -> int:
    os.makedirs(OUT_DIR, exist_ok=True)
    LABEL_CACHE.clear()
    try:
        health = get("/health", timeout=5)
    except Exception as error:  # noqa: BLE001 - any failure means "not running"
        print(f"The sidecar is not answering at {BASE}: {error}", file=sys.stderr)
        return 1
    if health.get("status") != "ok":
        print(f"Unexpected /health response: {health}", file=sys.stderr)
        return 1

    print(f"Recording and anonymizing from {BASE} -> {OUT_DIR}")

    # Re-recording everything re-fetches the account's whole library, and the
    # service's answers drift day to day, so a single fixture can be refreshed
    # on its own: `python tool/anonymize_fixtures.py recommendations`.
    if "recommendations" in sys.argv[1:]:
        record_recommendations()
        return _finish()

    write("health.json", {"status": "ok"})
    auth = get("/auth/status")
    write("auth_status.json", {"logged_in": bool(auth.get("logged_in")),
                               "error": None})
    write("account.json", scrub(get("/account")))

    # Row counts are trimmed so the fixtures stay small; the shapes are exact.
    write("home.json", scrub(get("/home")[:3]))
    write("search.json", scrub(get("/search?q=thriller")[:20]))
    for endpoint, name, count in (
        ("/library/songs", "library_songs.json", 10),
        ("/library/playlists", "library_playlists.json", 10),
        ("/library/albums", "library_albums.json", 10),
        ("/library/artists", "library_artists.json", 10),
        ("/library/liked", "library_liked.json", 10),
    ):
        write(name, scrub(get(endpoint)[:count]))

    albums = get("/library/albums")
    artists = get("/library/artists")
    write("artist.json", scrub(get(f"/artist/{artists[0]['browseId']}")))
    write("album.json", scrub(get(f"/album/{albums[0]['browseId']}")))

    playlist = scrub(get("/playlist/LM"))
    playlist["tracks"] = (playlist.get("tracks") or [])[:8]
    playlist["trackCount"] = len(playlist["tracks"])
    write("playlist.json", playlist)

    record_recommendations()

    return _finish()


def _finish() -> int:
    """Shared self-check and exit path for both recording modes."""
    findings = [issue for name, payload in WRITTEN
                for issue in self_check(name, payload)]
    if findings:
        print("\nSELF-CHECK FAILED — these fixtures still look like real data:",
              file=sys.stderr)
        for issue in findings[:20]:
            print(f"  {issue}", file=sys.stderr)
        return 2

    print("Self-check passed: no real URL or channel id survived.")
    print("Done. No raw response was written to the repository.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
