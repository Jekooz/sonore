# YTM Client — Phase 1 POC (Flutter)

This is the small, ugly-but-working playback proof of concept that `design.md`
section 5 asks for — the first implementation milestone, deliberately not the
Home screen. It exists to prove the risky path (authenticate → resolve a track →
play/seek/skip) before any of the real UI is built.

It talks to the **existing** FastAPI sidecar (`../backend/main.py`) and the
**existing** Python tests. Nothing in the WinUI app was modified.

## What is actually verified

| design.md §5 item | Status | Evidence |
|---|---|---|
| 1. Launch Flutter on Android | **verified** | `app-debug.apk` built (`apk_build4_exit=0`), installed on `emulator-5554` (`Success`), launched: pid `7750`, focused window `com.jekooz.ytm_poc/.MainActivity` |
| 1. Launch Flutter on Windows | **blocked (environment)** | `flutter doctor` → `[X] Visual Studio not installed`; Windows desktop builds need VS 2022 + "Desktop development with C++", which is not on this machine |
| 2. Sign in safely | **partially verified** | The flow code path is real (`/auth/browser/start` → poll `/auth/browser/status`, 2 s × 3 min). Completing it needs a real browser + Google account — a human step |
| 3. Play a real track | **not verified** | Requires a completed sign-in |
| 4. Pause / resume / seek / skip | **not verified** | Requires a completed sign-in; the seek policy itself is unit-tested |
| 5. Queue survives navigation | **not verified at runtime** | Implemented (queue lives above the navigator in `PocApp`); unit-tested; needs one manual back-and-forth |
| 6. Credentials not logged/exposed | **by construction** | The client never receives cookies/tokens: the sidecar owns the session (keyring). No auth payload, header or signed stream URL is ever printed. `/stream` URLs go straight from response to engine |
| 7. Existing Python suite unchanged | **verified** | `python -m pytest tests/` → `69 passed, 1 warning in 3.25s`, exit 0 |

Static + unit verification (all exit 0):

```
flutter analyze              → No issues found!
flutter test                 → 13/13 passed
flutter build apk --debug    → √ Built build\app\outputs\flutter-apk\app-debug.apk  (174,056,996 bytes)
python -m pytest tests/      → 69 passed
```

Client → sidecar connectivity was confirmed end to end: with `python
backend/main.py` running on port 8000, the app on the emulator produced
`GET /health`, `GET /health`, `GET /auth/status` in the server log — the exact
connect-then-refresh-auth sequence in `ApiClient.connect()`.

## Architecture (design.md §4 boundaries)

```
lib/
  main.dart                      // app + 2 screens; owns the services
  theme/tokens.dart              // §2 tokens: #000000 / #141417 / #FA2D48 / #A6A6A6 ...
  models/track.dart              // ytmusicapi row → Track (artists[] | artist | author)
  services/
    api_client.dart              // real HTTP to the sidecar endpoints
    playback_service.dart        // PlaybackService interface + media_kit impl
    seek_policy.dart             // pure clamp policy (no plugin import → testable)
    queue_service.dart           // queue above the navigator + pure index helpers
    player_controller.dart       // composes api + queue + playback for both screens
test/poc_logic_test.dart         // seek bounds, queue semantics, parsing, formatting
```

The UI never imports the audio engine: `initializePlaybackEngine()` is exposed by
the playback layer, so only `playback_service.dart` knows about media_kit.

### Why media_kit (design.md §4 says verify before committing)

Checked against pub.dev's API, not from memory:

| Package | Latest | Declared platforms |
|---|---|---|
| `media_kit` | 1.2.6 | Dart core (platforms come from the libs packages) |
| `media_kit_libs_android_audio` | 1.3.8 | `android` |
| `media_kit_libs_windows_audio` | 1.0.9 | `windows` |
| `just_audio` | 0.10.6 | android, ios, macos, web — **no Windows** |
| `just_audio_windows` | 0.2.3 | windows only, older (needs the separate plugin) |

One engine for both targets avoids a second audio stack and keeps the seek/
duration behaviour identical across platforms. `audio_service` is **not**
included yet: background playback is a §F/§5-phase concern, not a Phase 1 one.

## Running it

```bash
# 1. toolchain (this machine): Flutter 3.47.7 at ~/flutter, Temurin JDK 17
export PATH="$HOME/flutter/bin:$PATH"
export JAVA_HOME='C:\Program Files\Eclipse Adoptium\jdk-17.0.20.101-hotspot'
export ANDROID_HOME="$HOME/AppData/Local/Android/Sdk"   # add these to your profile to make them permanent

# 2. backend (spawned by the WinUI app in normal use)
python ../backend/main.py            # publishes %TEMP%\ytmusic_sidecar_port.txt

# 3. the emulator
"$ANDROID_HOME/emulator/emulator.exe" -avd ytm_poc_avd -gpu swiftshader_indirect

# 4. the app
flutter run -d emulator-5554
```

Base URL resolution: `--dart-define=YTM_BASE_URL=http://10.0.2.2:8003` overrides
everything; otherwise the desktop path reads `%TEMP%\ytmusic_sidecar_port.txt`
(the contract `SidecarLauncher` uses) and Android falls back to
`http://10.0.2.2:8000` (emulator alias for the host loopback).

## Environment workarounds applied (worth knowing, they are not project bugs)

1. winget has **no** Flutter SDK package — installed from the official stable zip.
2. The Gradle wrapper's own download timed out at the TLS layer under Java, so
   `gradle-9.3.1-all.zip` was fetched with curl and seeded into
   `~/.gradle/wrapper/dists/gradle-9.3.1-all/<hash>/` (+ the `.ok` marker).
3. `media_kit_libs_android_audio` downloads libmpv JARs with `URL.openStream()`
   and timed out the same way; all four JARs were seeded into
   `build/media_kit_libs_android_audio/v1.1.8/` with their **MD5s verified**
   against the checksums in the plugin's own `build.gradle`.
4. NDK `28.2.13676358` (required by `ndkVersion = flutter.ndkVersion`) was
   missing; installed with `android sdk install "ndk;28.2.13676358"` because
   `sdkmanager` is deprecated in cmdline-tools 23.0 and Flutter's automatic
   install path fails with it.

## Still to do (Phase 1 completion, needs a human)

1. Complete a real browser sign-in, then play one real track.
2. Drag the scrubber by hand: preview updates while dragging, exactly one seek
   is committed on release, position/time update afterwards.
3. Skip forward/back and confirm the queue count survives a back-and-forth.
4. Install VS 2022 + "Desktop development with C++" to unblock `flutter build windows`.

## Where this directory sits

`flutter_poc/` is a separate Flutter project — it is not part of
`YtMusicClient.sln` and does not affect the WinUI build. Nothing has been
committed (`git status` shows it as untracked), per the migration plan's
"separate branch" step, which is a human/git decision.
