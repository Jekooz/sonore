# YouTube Music Client for Windows — Project Context

## Stack
- Frontend: WinUI 3, .NET 8, C#, MVVM (CommunityToolkit.Mvvm), Segoe UI Variable.
- Visual style: Mica/Acrylic backdrop, translucent frosted‑glass cards, soft rounded corners,
  subtle shadows — Apple‑liquid‑glass feel but built on native Fluent Design materials, follows
  Windows accent color and light/dark theme automatically.
- Backend: Python 3.11 sidecar, FastAPI, ytmusicapi, yt‑dlp, keyring (Windows Credential Locker).
- Audio: NAudio (C#, frontend‑side) for decode → EQ → output, so the equalizer has real DSP access.
- Communication: frontend spawns backend subprocess on launch, HTTP over localhost, backend
  writes its chosen port to %TEMP%/ytmusic_sidecar_port.txt on boot.

## Navigation
Top tab bar: Home | Search | Library | Now Playing (like the YT Music web app).

## v2 — do NOT build now
Fallback to user's own Gonic/FLAC library for owned tracks, YT Music only for the rest.

## Non‑negotiables
- No mock data, no TODO stubs on in‑scope features, at any milestone.
- OAuth token is stored only via keyring/Credential Locker, never a plain file.
- Each milestone must end in a runnable checkpoint before the next one starts.
