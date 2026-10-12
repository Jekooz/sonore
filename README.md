# YT Music Client

A native Windows YouTube Music client with a liquid-glass WinUI 3 interface and a real
"Sign in with Google" flow — **no Google developer console setup, no device codes, nothing
to copy-paste**. Sign in once through your own browser and your playlists, liked songs,
subscribed artists, saved albums and channel subscriptions load straight into the client.

![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-blue)
![Frontend](https://img.shields.io/badge/frontend-WinUI%203%20%2F%20.NET%208-5C2D91)
![Backend](https://img.shields.io/badge/backend-Python%20%2F%20FastAPI-009688)

---

## How sign-in works (and why there are no codes)

Older builds (and most ytmusicapi-based tools) use Google's *device code* flow: the app
shows a URL and a code, you open a browser, type the code, approve the device. This app
does none of that. (It also no longer embeds a browser — the flow runs in *your* browser.)

Instead:

1. Click **Sign in with Google** on any tab. The app asks the local backend to start a
   browser sign-in and shows a waiting overlay while it polls for the result.
2. Your **default browser** opens `music.youtube.com`. You sign in with your normal Google
   account — Google's usual checks (2FA, "verify it's you") happen right there, on Google's
   own page.
3. Click the **YT Music Client Helper** extension's toolbar button (a one-time
   [Manifest V3 helper](browser-extension/) you load unpacked — see step 4 below). The
   extension reads the session cookies — including `HttpOnly` cookies like
   `__Secure-3PAPISID` that page JavaScript cannot touch — and hands them to the local
   backend over `http://127.0.0.1:<port>/auth/extension`.
4. The backend validates them the same way the music.youtube.com web player would —
   ytmusicapi's *browser authentication* — and stores them in the **Windows Credential
   Locker** (OS keyring), never in a plain file. The overlay reports success and the app
   loads your library.

From then on the app starts already signed in. If Google ever expires the session, the app
detects it and offers the same one-click sign-in again.

> **Privacy note:** your cookies never leave your machine. They are stored only in the
> Windows Credential Locker and used only against `music.youtube.com` from your local
> backend process. The extension sends them only to `127.0.0.1` and stores nothing itself.
> No telemetry, no third parties, no plain-text files on disk.

---

## Features

- **Sign in with Google** — default browser, one helper-extension click, zero code copying
- **Home** — your real personalized YouTube Music home rows (mixes, recommendations, new releases)
- **Library** — five live sections, straight from your account:
  - Playlists (with track counts)
  - Subscribed artists (with subscriber counts)
  - Saved albums
  - Liked songs (title / artist / duration rows)
  - Channel subscriptions
- **Search** — songs, albums, artists and playlists across all of YouTube Music, with
  debounced typeahead and recent-search history
- **Playback** — streams real audio (yt-dlp resolves the stream, NAudio decodes → EQ →
  output): queue with previous/next history, seek + buffered bar, volume with a perceptual
  curve, shuffle/repeat, like, autoplay, System Media Transport Controls (media keys,
  lock screen) and keyboard shortcuts — Space play/pause, ←/→ seek ±5 s, ↑/↓ volume ±5 %.
  The next track's stream URL is prefetched at 50 % played.
- **Now Playing** — artwork carousel with previous/next preview cards and the full
  transport. The page *is* the player: it hides the mini-player, collapses the sidebar
  into a hamburger, drops the carousel side cards below 700 px of width, and scrolls
  vertically instead of clipping at compact heights.
- **Persistent mini-player** — every other tab keeps a rounded glass player bar in its own
  dedicated shell grid row, so page scrolling never runs behind it. The window enforces a
  320-logical-pixel minimum height (WM_GETMINMAXINFO) so the bar's bottom corners and
  controls are never clipped, even at the smallest window size.
- **Design** — true-black glass UI per `DESIGN_TOKENS.md`: frosted-glass cards, sidebar
  navigation (hamburger on Now Playing), single accent color, artwork-driven cards

## Architecture

```
┌────────────────────────────┐   spawns    ┌─────────────────────────────┐
│  WinUI 3 frontend (C#)     │────────────▶│  Python sidecar (FastAPI)   │
│  - glass shell, 4 tabs     │  HTTP on    │  - ytmusicapi (YT Music)    │
│  - browser-assisted sign-in│  127.0.0.1  │  - keyring (Credential      │
│  - NAudio (playback)       │             │    Locker storage)          │
└────────────────────────────┘             └─────────────────────────────┘
```

- The frontend launches the backend as a child process and discovers its port via
  `%TEMP%\ytmusic_sidecar_port.txt` (falls back to `8000`; the backend honors `YTM_PORT`).
- All YouTube Music access is server-side in Python via [ytmusicapi](https://github.com/sigma67/ytmusicapi),
  so the frontend only deals with clean JSON.
- Auth headers live in the OS keyring under the `ytmusic_client` service name.
- Playback streams through the backend's `/stream/{videoId}` endpoint (cached yt-dlp
  resolve); at 50 % played the frontend hits `/prefetch/{videoId}` so the next track's
  URL is already warm when you need it.

## Getting started

### Prerequisites

- Windows 10 1809+ or Windows 11
- [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0) (x64)
- Python 3.10+ on your PATH as `python` (3.11 recommended)
- A Chromium-based browser (Chrome/Edge) for the sign-in helper extension

### 1. Backend dependencies

From the repo root:

```bash
pip install -r backend/requirements.txt
```

(`fastapi`, `uvicorn`, `ytmusicapi`, `keyring`)

### 2. Build & run

```bash
dotnet build YtMusicClient.sln -c Debug -p:Platform=x64
```

Then run the app — it starts the backend itself:

```
frontend\bin\x64\Debug\net8.0-windows10.0.19041.0\YtMusicClient.exe
```

Or with `dotnet run`:

```bash
dotnet run --project frontend -c Debug -p:Platform=x64
```

### 3. Tests

```bash
# frontend: queue, playback, sidecar, window/nav layout contracts (xUnit)
dotnet test tests/YtMusicClient.Tests.csproj -c Debug -p:Platform=x64

# backend: auth pairing + recommendation ranking (pytest)
python -m pytest tests/
```

### 4. Load the helper extension (once)

The extension is what hands your browser session to the app. In your Chromium-based
browser: open `chrome://extensions` → enable **Developer mode** → **Load unpacked** →
pick the `browser-extension/` folder.

### 5. Sign in

Click **Sign in with Google** on the Home or Library tab, complete the Google sign-in in
the browser window that opens, then click the **YT Music Client Helper** icon in the
toolbar. The app picks it up automatically. That's the whole process.

## Backend API reference

Base URL: `http://127.0.0.1:<port>` (port from `%TEMP%\ytmusic_sidecar_port.txt`)

| Method | Path                      | Description                                     |
|--------|---------------------------|-------------------------------------------------|
| GET    | `/health`                 | Liveness probe → `{"status": "ok"}`             |
| GET    | `/auth/status`            | `{"logged_in": bool, "error": str\|null}`       |
| POST   | `/auth/cookies`           | Complete sign-in. Body: `{"cookies": {...}}`    |
| POST   | `/auth/signout`           | Forget the stored session                       |
| GET    | `/auth/browser/info`      | Default browser name (for the UI prompt)        |
| POST   | `/auth/browser/start`     | Open music.youtube.com in the default browser   |
| GET    | `/auth/browser/status`    | Poll until the extension delivers the cookies   |
| POST   | `/auth/browser/cancel`    | Abort a pending browser sign-in                 |
| POST   | `/auth/extension`         | Cookie hand-off from the MV3 helper extension   |
| GET    | `/account`                | Account name, handle, photo URL                 |
| GET    | `/home`                   | Personalized home rows                          |
| GET    | `/library/playlists`      | Your playlists                                  |
| GET    | `/library/artists`        | Subscribed artists                              |
| GET    | `/library/albums`         | Saved albums                                    |
| GET    | `/library/songs`          | Saved songs                                     |
| GET    | `/library/liked`          | Liked songs (track list)                        |
| GET    | `/library/subscriptions`  | Channel subscriptions                           |
| GET    | `/album/{browse_id}`      | Album detail + track list                       |
| GET    | `/playlist/{playlist_id}` | Playlist detail + track list                    |
| GET    | `/artist/{channel_id}`    | Artist detail + top songs                       |
| GET    | `/search?q=…`             | Search songs/albums/artists/playlists           |
| GET    | `/radio?videoId=…`        | YT Music radio for one seed song                |
| GET    | `/recommendations?seed=…` | Autoplay: ranked candidates as the queue runs low |
| POST   | `/listening/events`       | Aggregated playback events (feeds recommendations) |
| POST   | `/ratings`                | Like / dislike via `rate_song`                  |
| GET    | `/prefetch/{video_id}`    | Warm the stream-URL cache (fire-and-forget)     |
| GET    | `/stream/{video_id}`      | Stream the track's audio                        |

All `/account`, `/home`, `/library/*` and `/search` endpoints return `401` when signed
out or when the session has expired, and `502` with a readable message if YouTube Music
itself fails.

## Troubleshooting

**The app says "Backend not reachable"**
- Make sure `pip install -r backend/requirements.txt` succeeded for the *same* Python the
  app launches as `python` (`python --version`).
- Port 8000 busy? Start the backend manually with a custom port — the app reads the port
  file either way:
  ```bash
  YTM_PORT=8765 python backend/main.py
  ```

**Sign-in did not complete**
- Make sure you ended up signed in to **music.youtube.com** in the browser window that
  opened (your account avatar should appear on the page), then clicked the **YT Music
  Client Helper** extension's toolbar button. The button is missing if the extension is
  not loaded yet — see step 4 above. Corporate/managed accounts sometimes block YouTube
  Music — try a personal account.

**"Session expired" after working before**
- Google rotated your session. Just sign in again from the Home tab; the stored session is
  replaced automatically.

**Where are my credentials stored?**
- In the Windows Credential Locker (Control Panel → Credential Manager → Windows
  Credentials, entry `ytmusic_client`). Nothing is ever written to disk in plain text, and
  signing out (or clearing the entry) removes it completely.

## Project layout

```
backend/
  main.py                     FastAPI app: auth, data, radio/autoplay, stream + prefetch
  services/
    ytmusic_client.py         Cookie-based auth, keyring storage, YTMusic factory
    browser_auth.py           Browser-assisted sign-in orchestration
    recommend.py / ranking.py Recommendations over the local listening store
    listening.py              Playback-feedback events
  requirements.txt
browser-extension/
  manifest.json / popup.* / service_worker.js   MV3 helper: hands cookies to the backend
frontend/
  App.xaml(.cs)               Entry point, sidecar startup, shared state
  Views/
    MainWindow.xaml(.cs)      Shell: title bar, sidebar/hamburger, persistent player bar
    HomePage / SearchPage / LibraryPage / NowPlayingPage / CollectionPage
    Controls/BufferedSeekBar  Seek bar with buffered segment
  Services/
    ApiClient.cs              Typed sidecar client (snake_case DTO mapping)
    SidecarLauncher.cs        Backend process + port discovery
    PlaybackService.cs        Queue, resolve, prefetch; AudioEngine.cs = NAudio output
    PlayerState / QueueManager / SmtcController / SearchHistory / ...
  Themes/                     Design tokens + nav styles (DESIGN_TOKENS.md)
tests/
  ServiceTests.cs             xUnit: queue, playback, sidecar, window/nav layout contracts
  test_recommendations.py     pytest: recommendation ranking
  test_auth_pairing.py        pytest: auth pairing
```

## Roadmap

- **Lyrics view**, playlist management (create/reorder), thumbs up/down from the app
- **v2 (deliberately deferred)** — fallback to a local Gonic/FLAC library for owned tracks

## Disclaimer

This is an unofficial client. It talks to YouTube Music the same way your browser does,
using your own session, through the open-source
[ytmusicapi](https://github.com/sigma67/ytmusicapi) library. Use it responsibly and within
YouTube's Terms of Service.
