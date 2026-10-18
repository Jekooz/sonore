<img src="ytm_app/assets/brand/sonore-icon.svg" width="96" height="96" alt="Sonore app icon">

# Sonore

![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-blue)
![Frontend](https://img.shields.io/badge/frontend-Flutter%20desktop-02569B)
![Backend](https://img.shields.io/badge/backend-Python%20%2F%20FastAPI-009688)
[![Latest release](https://img.shields.io/github/v/release/Jekooz/sonore?include_prereleases&label=release)](https://github.com/Jekooz/sonore/releases)

An unofficial YouTube Music client for Windows: a Flutter desktop app driven by
a small local Python service. Playback, search, library and account data come
from a FastAPI sidecar on `127.0.0.1`; the app never talks to YouTube directly
and never ships credentials.

Current version: **1.6.1** (tracked in `VERSION`). Status: working desktop app,
actively developed — the latest GitHub release carries the single-file installer.
The backend pairing gate and the light-palette redesign are work in progress on
separate branches and are not part of this tree.

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
- **Sign-in** — sign in through your own browser with the bundled helper
  extension (`browser-extension/`). The app opens music.youtube.com and waits
  while the extension's **Connect** button hands the session to the local
  service over a loopback-only endpoint (`POST /auth/handoff`); only one
  pairing attempt can be in flight per session, so a stale attempt can never
  steal the hand-off. A "paste request headers" fallback in Settings → Account
  feeds the same endpoint when the extension cannot be loaded. The session is
  stored encrypted on this device, an expired session is reported as
  signed-out (not broken), and a failed sign-in never damages a working one.
- **Ten-band equalizer** — per-band gain on top of media_kit's audio bindings,
  with named presets and manual editing (`ytm_app/lib/audio/`,
  `ytm_app/lib/features/equalizer/`).
- **Settings** — reduce transparency, reduce motion, text scale, equalizer and
  playback preferences; all persisted with `shared_preferences`.

## Not done yet (roadmap)

- Offline downloads of playlists/albums.
- Windows system media controls (SMTC) and a per-app volume mixer.
- Gonic/Music-Provider FLAC fallback when YouTube audio quality is the cap.

## Installing

Grab `Sonore-Setup-<version>.exe` from
[Releases](https://github.com/Jekooz/sonore/releases) and run it. It installs for
every account on the machine into `C:\Program Files\Sonore` (one UAC prompt, then
an entry in **Add or remove programs** and an uninstaller), and it carries
everything the app needs at run time — nothing has to be installed first:

- the Flutter app, its engine and its assets;
- a private CPython 3.11 with `fastapi`, `uvicorn`, `ytmusicapi` and `keyring`
  from `backend/requirements.txt` already installed into it;
- the backend itself (`backend/main.py` and its services);
- `yt-dlp.exe`, the binary the backend resolves with `shutil.which` for the
  `/stream/{video_id}` endpoint;
- the sign-in helper extension, in the `browser-extension` folder beside the
  app. **Sign-in cannot complete without it**: a browser only lets an extension
  read a file inside its own folder, so a copy loaded from anywhere else can
  never hand the session over. Load it unpacked from that folder (your browser's
  extension page, Developer mode, "Load unpacked"); the sign-in screen and the
  Setup wizard's last page both name it, and the sign-in screen can open it.

The app starts the Python it shipped with rather than whatever happens to be on
the machine, so the packages it runs against are fixed by the installer. Setting
`YTM_PYTHON` still overrides that while debugging. Microsoft's Visual C++
2015-2022 runtime is installed too, but only when the machine does not already
have it.

## Requirements for running from source

- **Flutter SDK** (stable channel; the app targets Windows and also builds
  for Android).
- **Python 3** with `fastapi`, `uvicorn`, `ytmusicapi` and `keyring`
  (`backend/requirements.txt`).
- **yt-dlp** on your `PATH`. The backend resolves it with `shutil.which`,
  and the `/stream/{video_id}` endpoint shells out to it for audio URLs.

## Running from source

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
python -m pytest tests -q             # 111 backend/UI-pairing tests
cd ytm_app && flutter test            # 349 widget and unit tests
```

## Architecture

Flutter (Riverpod + go_router, media_kit for playback) talking over `http` to a
local FastAPI service that wraps `ytmusicapi` and `yt-dlp` on `127.0.0.1`.
Sign-in is performed in your own browser; the session the backend derives from
it is stored **encrypted on this device** and token/cookie values are never
logged (the Settings page states this too). Only the paired sidecar instance is
trusted; nothing outside the local machine talks to the service.

## Building the installer

`packaging\build_installer.ps1` produces `dist\Sonore-Setup-<version>.exe`. It
builds the Windows release of the app, builds the private Python runtime by
unpacking the official embeddable CPython and running
`pip install -r backend\requirements.txt` into it, downloads `yt-dlp.exe` and
Microsoft's VC++ redistributable, stages the installed layout, and compiles
`packaging\sonore.iss` with Inno Setup.

```
powershell -ExecutionPolicy Bypass -File packaging\build_installer.ps1
```

The Flutter SDK and Inno Setup 6 (`winget install JRSoftware.InnoSetup`) are the
only tools it needs. Downloads are cached under `build\packaging\cache`, so a
second run is much faster, and `-SkipAppBuild`, `-SkipRuntimeBuild` and
`-SkipInstaller` rebuild just one stage. The script refuses to build when the
version in `packaging\sonore.iss` no longer matches `ytm_app\pubspec.yaml`.

## Credits

Inter (typeface) — The Inter Project, MIT License.
Phosphor icons (icon set) — Phosphor Icons, MIT License.

## License

There is no LICENSE file in the repository yet. Nothing in this repo grants or
denies distribution rights; add a license before treating this as reusable.
