# YT Music Client

A native Windows YouTube Music client with a liquid-glass WinUI 3 interface and a real
"Sign in with Google" flow — **no developer console setup, no device codes, nothing to
copy-paste**. Sign in once inside the app and your playlists, liked songs, subscribed
artists, saved albums and channel subscriptions load straight into the client.

![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-blue)
![Frontend](https://img.shields.io/badge/frontend-WinUI%203%20%2F%20.NET%208-5C2D91)
![Backend](https://img.shields.io/badge/backend-Python%20%2F%20FastAPI-009688)

---

## How sign-in works (and why there are no codes)

Older builds (and most ytmusicapi-based tools) use Google's *device code* flow: the app
shows a URL and a code, you open a browser, type the code, approve the device. This app
does none of that.

Instead:

1. On first launch, a **sign-in window with an embedded browser** (WebView2) opens at
   `music.youtube.com`.
2. You sign in with your normal Google account — the same way you would in any browser.
   Google may run its usual checks (2FA, "verify it's you"); they all happen right there.
3. The moment YouTube Music loads signed-in, the app reads the **session cookies from the
   embedded browser's cookie jar** (via WebView2's `CookieManager`, which can read
   `HttpOnly` cookies like `__Secure-3PAPISID` that JavaScript cannot touch).
4. Those cookies are handed to the local backend, which uses them exactly the way the
   music.youtube.com web player does — ytmusicapi's *browser authentication* — and stores
   them in the **Windows Credential Locker** (OS keyring), never in a plain file.

From then on the app starts already signed in. If Google ever expires the session, the app
detects it and offers the same one-click sign-in again.

> **Privacy note:** your cookies never leave your machine. They are stored only in the
> Windows Credential Locker and used only against `music.youtube.com` from your local
> backend process. No telemetry, no third parties, no plain-text files on disk.

---

## Features

- **Sign in with Google** — embedded browser, zero code copying
- **Home** — your real personalized YouTube Music home rows (mixes, recommendations, new releases)
- **Library** — five live sections, straight from your account:
  - Playlists (with track counts)
  - Subscribed artists (with subscriber counts)
  - Saved albums
  - Liked songs (title / artist / duration rows)
  - Channel subscriptions
- **Search** — songs, albums, artists and playlists across all of YouTube Music
- **Design** — true-black glass UI per `DESIGN_TOKENS.md`: pill tab bar in the title bar,
  single accent color, artwork-driven cards

## Architecture

```
┌────────────────────────────┐   spawns    ┌─────────────────────────────┐
│  WinUI 3 frontend (C#)     │────────────▶│  Python sidecar (FastAPI)   │
│  - glass shell, 4 tabs     │  HTTP on    │  - ytmusicapi (YT Music)    │
│  - WebView2 sign-in window │  127.0.0.1  │  - keyring (Credential      │
│  - NAudio (playback, soon) │             │    Locker storage)          │
└────────────────────────────┘             └─────────────────────────────┘
```

- The frontend launches the backend as a child process and discovers its port via
  `%TEMP%\ytmusic_sidecar_port.txt` (falls back to `8000`; the backend honors `YTM_PORT`).
- All YouTube Music access is server-side in Python via [ytmusicapi](https://github.com/sigma67/ytmusicapi),
  so the frontend only deals with clean JSON.
- Auth headers live in the OS keyring under the `ytmusic_client` service name.

## Getting started

### Prerequisites

- Windows 10 1809+ or Windows 11
- [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0) (x64)
- Python 3.10+ on your PATH as `python` (3.11 recommended)

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

### 3. Sign in

Click **Sign in with Google** on the Home or Library tab, complete the Google sign-in in
the embedded window, and the app takes it from there. That's the whole process.

## Backend API reference

Base URL: `http://127.0.0.1:<port>` (port from `%TEMP%\ytmusic_sidecar_port.txt`)

| Method | Path                    | Description                                    |
|--------|-------------------------|-----------------------------------------------|
| GET    | `/health`               | Liveness probe → `{"status": "ok"}`           |
| GET    | `/auth/status`          | `{"logged_in": bool, "error": str\|null}`     |
| POST   | `/auth/cookies`         | Complete sign-in. Body: `{"cookies": {...}}`  |
| POST   | `/auth/signout`         | Forget the stored session                     |
| GET    | `/account`              | Account name, handle, photo URL               |
| GET    | `/home`                 | Personalized home rows                        |
| GET    | `/library/playlists`    | Your playlists                                |
| GET    | `/library/artists`      | Subscribed artists                            |
| GET    | `/library/albums`       | Saved albums                                  |
| GET    | `/library/songs`        | Saved songs                                   |
| GET    | `/library/liked`        | Liked songs (track list)                      |
| GET    | `/library/subscriptions`| Channel subscriptions                         |
| GET    | `/search?q=…`           | Search songs/albums/artists/playlists         |

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

**Sign-in window says sign-in could not be verified**
- Make sure you ended up signed in to **music.youtube.com** in the embedded window (check
  that your account avatar appears on the web page). Corporate/managed accounts sometimes
  block YouTube Music — try a personal account.

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
  main.py                     FastAPI app: auth + data endpoints
  services/ytmusic_client.py  Cookie-based auth, keyring storage, YTMusic factory
  requirements.txt
frontend/
  App.xaml(.cs)               Entry point, sidecar startup, shared state
  Views/
    MainWindow.xaml(.cs)      Glass chrome, tab bar, sign-in orchestration
    SignInWindow.xaml(.cs)    Embedded WebView2 Google sign-in + cookie capture
    HomePage / SearchPage / LibraryPage / NowPlayingPage
  Services/
    ApiClient.cs              Typed sidecar client (snake_case DTO mapping)
    BindableModels.cs         XAML-friendly view wrappers
    SidecarLauncher.cs        Backend process + port discovery
  Themes/                     Design tokens + nav styles (DESIGN_TOKENS.md)
```

## Roadmap

- **Playback** — stream URLs via yt-dlp, decode + EQ through NAudio, queue fan carousel
- **Lyrics view**, playlist management (create/reorder), thumbs up/down from the app
- **v2 (deliberately deferred)** — fallback to a local Gonic/FLAC library for owned tracks

## Disclaimer

This is an unofficial client. It talks to YouTube Music the same way your browser does,
using your own session, through the open-source
[ytmusicapi](https://github.com/sigma67/ytmusicapi) library. Use it responsibly and within
YouTube's Terms of Service.
