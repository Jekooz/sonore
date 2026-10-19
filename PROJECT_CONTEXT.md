# YouTube Music Client for Windows — Project Context

## Stack
- Frontend: WinUI 3, .NET 8, C#, MVVM (CommunityToolkit.Mvvm), Segoe UI Variable.
- Visual style: Mica/Acrylic backdrop, translucent frosted‑glass cards, soft rounded corners,
  subtle shadows — Apple‑liquid‑glass feel but built on native Fluent Design materials, follows
  Windows accent color and light/dark theme automatically.
- Backend: Python 3.11 sidecar, FastAPI, ytmusicapi, yt‑dlp, keyring (Windows Credential Locker).
- Audio: NAudio (C#, frontend‑side) for decode → EQ → output, so the equalizer has real DSP access.
- Communication: frontend spawns backend subprocess on launch, HTTP over localhost, backend
  writes its chosen port to %LOCALAPPDATA%\Sonore\sidecar_port.txt on boot.
  (%TEMP%/ytmusic_sidecar_port.txt was the pre-1.6.1 location and is still read as a
  fallback, so an older sidecar keeps working.)

## Navigation
Top tab bar: Home | Search | Library | Now Playing (like the YT Music web app).

## v2 — do NOT build now
Fallback to user's own Gonic/FLAC library for owned tracks, YT Music only for the rest.

## Non‑negotiables
- No mock data, no TODO stubs on in‑scope features, at any milestone.
- The YouTube Music session is captured from the browser the user set as default
  in Windows — in a profile the app owns for a Chromium browser, or from the
  user's own Firefox profile, which is readable in place. There is no helper
  extension to install and no OAuth device-code flow to fall back on; Google
  removed it. The session is stored encrypted on this device (DPAPI, via keyring
  where that fits), never as a plain file.
- Each milestone must end in a runnable checkpoint before the next one starts.
