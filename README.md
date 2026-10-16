# ytm-client

A Flutter Windows desktop client for YouTube Music, driven by a small local Python
service. Playback, search, library and account data come from a FastAPI sidecar on
`127.0.0.1`; the app never talks to YouTube directly and never ships credentials.

Status: working desktop app, actively developed. The backend pairing gate and the
light-palette redesign are work in progress on separate branches and are not
part of this tree.

## Screenshots

Not yet added. If you want screenshots in the README, add these files and
reenable the section:

- `docs/screenshots/home.png`
- `docs/screenshots/search.png`
- `docs/screenshots/now-playing.png`
- `docs/screenshots/equalizer.png`
- `docs/screenshots/settings.png`

## What works today

Everything below is present in the code on this branch:

- **Home feed** — hero banner with a Follow button, content shelves, and a
  Popular rail (`ytm_app/lib/features/home/`).
- **Search** — full-catalog search backed by the backend's `/search` endpoint.
- **Library** — playlists, artists, albums, songs, liked tracks and channel
  subscriptions (`/library/*` endpoints); you can follow and unfollow artists.
- **Now Playing** — album art wash behind the whole screen, a "cue card" that
  rotates future tracks toward the front, an "Up Next" panel, and a full queue
  screen with history.
- **Mini player** — persistent across tabs, with play/pause/next/transport.
- **Autoplay** — picks up the next track when enabled in settings.
- **Shuffle and repeat** — off / all / one, persisted between runs.
- **Synced lyrics** — lyric lines with timestamps; the screen follows playback
  and seek-by-tap when a synced source is available.
- **Ten-band equalizer** — per-band gain on top of media_kit's audio bindings,
  with named presets and manual editing (`ytm_app/lib/audio/`,
  `ytm_app/lib/features/equalizer/`).
- **Settings** — reduce transparency, reduce motion, text scale, equalizer and
  playback preferences; all persisted with `shared_preferences`.

## Not done yet (roadmap)

- Offline downloads of playlists/albums.
- Windows system media controls (SMTC) and a per-app volume mixer.
- A packaged Windows installer.
- Gonic/Music-Provider FLAC fallback when YouTube audio quality is the cap.

## Requirements

- **Flutter SDK** (stable channel; the app targets Windows and also builds
  for Android).
- **Python 3** with `fastapi`, `uvicorn`, `ytmusicapi` and `keyring`
  (`backend/requirements.txt`).
- **yt-dlp** on your `PATH`. The backend resolves it with `shutil.which`,
  and the `/stream/{video_id}` endpoint shells out to it for audio URLs.

## Running

1. Install the backend dependencies:

   ```
   pip install -r backend/requirements.txt
   ```

   and make sure `yt-dlp` is on your `PATH` (`winget install yt-dlp`).

2. Start the sidecar:

   ```
   cd backend
   uvicorn main:app --host 127.0.0.1
   ```

   It binds to `127.0.0.1` and writes the chosen port to
   `%TEMP%\ytmusic_sidecar_port.txt` for discovery.

3. Run the app:

   ```
   cd ytm_app
   flutter pub get
   flutter run -d windows
   ```

The app can also start the sidecar itself at launch (`lib/core/sidecar/`);
a stale port file is detected and a fresh backend is spawned in that case.

## Running the tests

```
python -m pytest tests -q             # 85 backend/UI-pairing tests
cd ytm_app && flutter test            # 326 widget and unit tests
```

## Architecture

Flutter (Riverpod + go_router, media_kit for playback) talking over `http` to a
local FastAPI service that wraps `ytmusicapi` and `yt-dlp` on `127.0.0.1`.
Sign-in is performed in your own browser; the session the backend derives from
it is stored **encrypted on this device** and token/cookie values are never
logged (the Settings page states this too). Only the paired sidecar instance is
trusted; nothing outside the local machine talks to the service.

## Credits

Inter (typeface) — The Inter Project, MIT License.
Phosphor icons (icon set) — Phosphor Icons, MIT License.

## License

There is no LICENSE file in the repository yet. Nothing in this repo grants or
denies distribution rights; add a license before treating this as reusable.
