# Round 3 audit — round-1 items 1–10

Verdicts written before implementation (per round-3 instructions). Paths relative to `ytm_app/`.

| # | Item | Verdict | Evidence |
|---|------|---------|----------|
| 1 | Windows native window material + fallback | PARTIAL | `lib/main.dart:47-55` initializes `flutter_acrylic` and sets `WindowEffect.mica` inside try/catch (Win10 falls back to the plain surface). Nothing disables the material when **Reduce transparency** or OS **high contrast** is on — the in-app surfaces go solid while the window material stays Mica. |
| 2 | Custom title bar (drag, dbl-click maximize, snap layouts, min/max/close) | PARTIAL | `lib/features/shell/window_title_bar.dart:12-93` implements drag-to-move, double-click maximize, min/max/close via `window_manager` (wired in `lib/main.dart:154-185`). **Snap layouts** are missing: with `TitleBarStyle.hidden` the OS never shows its maximize-button flyout, and no custom snap menu exists. Win+arrow OS snapping still works. |
| 3 | Android launcher label "Sonore" + app-name strings | DONE | `android/app/src/main/AndroidManifest.xml` `android:label="Sonore"`; window title uses `appName` (`lib/main.dart:35`), all about/settings strings come from `lib/core/app_identity.dart` (`Sonore`). |
| 4 | Single tokens file; no magic numbers | PARTIAL | `lib/theme/tokens.dart` covers 4/8 spacing, type scale, radii, durations/curves and the round-2 sweep replaced raw paddings. Remaining strays: `lib/features/equalizer/equalizer_screen.dart:238` (raw `minHeight: 2`), `lib/features/player/lyrics_panel.dart:122,185` (raw skeleton/gutter widths), `lib/ui/context_menu.dart:35` (`_menuWidth = 232`), `lib/ui/live_badge.dart:34-35` (raw gap/width consts). |
| 5 | Designed loading/empty/error-retry/offline on every screen | PARTIAL | Skeletons via `screen_states.dart`, data/empty/error via `data_states.dart`, offline via `ConnectionGate`. Gaps: the equalizer error `StateMessage` offers no retry (`lib/features/equalizer/equalizer_screen.dart:242`); raw `CircularProgressIndicator` instead of the designed loader in `lib/core/sidecar/sidecar_startup_gate.dart:154` and `lib/features/settings/settings_screen.dart:336`. |
| 6 | Keyboard nav, focus rings, shortcuts, right-click track menu | PARTIAL | Global Space/arrows shortcuts, Esc closes panels, visible focus rings on `Pressable` (lib/ui/pressable.dart). Right-click menu has play next / add to queue / go to artist / go to album (`lib/ui/media_actions.dart:86-150`) but **"Add to playlist"** is absent; **↑/↓ volume** shortcuts and **hardware media keys** are not handled. |
| 7 | Search: instant+debounced, recents, grouped, keyboard-selectable | PARTIAL | Debounced instant search (`lib/features/search/search_controller.dart:62-129`), grouped Songs/Artists/Albums/Playlists (`search_screen.dart:279-296`). Recent searches are session-only, never persisted (`search_controller.dart:135-143`). Results are tab-focusable but there is no arrow-key walk from the field into results. |
| 8 | Motion: 150–250 ms curves, artwork hero, route transitions, reduce-motion gated | MISSING | Duration/curve tokens exist (`tokens.dart` dPageChange200/dFadeIn200), `MediaQuery.disableAnimations` gating exists app-wide (`lib/app.dart:44-57`), but there is **no `PageTransitionsTheme`, no `Hero`**, and no artwork flight into Now Playing anywhere in lib/. |
| 9 | Accessibility: semantics, 1.3 text scale, contrast on glass | PARTIAL | Semantics/tooltip labels on icon buttons, `MediaQuery.withClampedTextScaling` to 1.3 (`lib/app.dart:52-55`) with golden coverage; contrast verified in round-2 report. Gaps: user-content text still uses caption-contrast in a few spots; `TooltipThemeData` is not tokenized (Material defaults). |
| 10 | Reduce transparency: every surface solid; auto-engage high-contrast/low-end | PARTIAL | `GlassSurface` solid path includes OS high contrast (`lib/ui/glass_surface.dart:115-155`); menus/dialogs/SnackBar are already opaque and tokenized. Gaps: title-bar/window material (item 1), tooltips untokenized (item 4/9), and no automatic engage on low-end Android (paired with C2 quality tier). |

## Round-2 leftovers (Part A)
- A1: playlist header actions are a `Wrap` with `WrapCrossAlignment.center` (`lib/features/collection/collection_screen.dart:176`); at 390 px the lone "…" wraps onto a centered second line. Fix: compact icon-only actions at narrow width so title + actions stay on one row at 800 and 390.
- A2: Library, playlist/album (collection) and queue pages do not use the shared centered content column (`library_screen.dart:153-159`, `collection_screen.dart:105-111`, `queue_screen.dart:79,317`); no shared `ContentColumn` widget exists — create one and apply.

## Round 3 implementation outcome

Written after implementation, against the verdicts above.

| # | Item | After |
|---|------|-------|
| 1 | Window material | DONE. `lib/features/shell/window_material.dart`: Reduce transparency (or OS high contrast) swaps Mica for a solid `Tokens.bg` fill, at boot and live via the Settings toggle (`app.dart` listens + rebuild path). |
| 2 | Title bar | DONE (app's own snap menu). The OS Snap-layouts flyout is architecturally unavailable over `TitleBarStyle.hidden`; the maximize button's right-click/long-press menu offers Snap left / Snap right / Maximize–Restore (`window_title_bar.dart`), docking via `window_manager` to the work area of the window's own monitor, found with user32 `MonitorFromWindow`+`GetMonitorInfoW` through dart:ffi (`lib/features/shell/window_snap.dart`). |
| 3 | Android label | Was DONE, unchanged. |
| 4 | Tokens | DONE. `Tokens.menuWidth`, `liveBadgeBarWidth/Gap`, `skeletonLineBase/Step` added; all audited strays now read from tokens. |
| 5 | States | DONE. Equalizer error has **Try again** (re-runs the engine write via `applyToEngine`, `equalizer_screen.dart`); the Settings save banner and the startup gate use the designed `Skeleton` loader instead of raw spinners. |
| 6 | Keyboard | DONE except two documented gaps below. `Pressable` is now a real keyboard control (tab-reachable, Enter/Space activation, keyboard-only focus ring, new `focusRing` tokens); hardware media keys (play/pause, stop, next, previous) answer globally even while typing; search results walk with ↑/↓ (`VerticalFocusWalk` + shared traversal group); recent queries persist across launches (`search.recentQueries`). Gaps: **↑/↓ volume** and **Add to playlist** — see below. |
| 7 | Search | DONE. Recents persist (shared_preferences, degrades to session-only if the store fails); arrow-key walk from the field into and across the results. |
| 8 | Motion | DONE. `AppPageTransitions` in `app_theme.dart`: fade+rise, 200 ms, Reduce Motion folds it into a 150 ms cross-fade. Artwork Hero flight Home card → collection page (`_CardArt` + collection header), tags deduped first-come per artwork so the mounted tree never holds duplicates. |
| 9 | Accessibility | DONE. `TooltipThemeData` tokenized (solid, concentric, border rim); remaining caption-contrast on *user content* swept to subtitle (card subtitle lines); what stays caption is durations, numerals, source attribution — microcopy by design. |
| 10 | Reduce transparency | DONE. Tooltips solid/tokenized; low-end engage arrives through the Visual quality tier (item C2); window material follows the preference (item 1). |

### Part A leftovers
- A1: DONE — `collection_screen.dart` header actions fall back in two steps (labels → icons under 360 px → all icons under 240 px, icon-only pills are square 48 px); title and actions share one row at 390 and 800, verified in the re-captured shots.
- A2: DONE — `lib/ui/content_column.dart` (`ContentColumn`); Library, collection pages and Queue now center/cap at `Tokens.contentMaxWidth` like Home and Search.

### Part C
- C1: DONE — release APK built (`build/app/outputs/flutter-apk/app-release.apk`, 73.7 MB); `docs/PERF_CHECKLIST.md` documents the five scenarios, what to read and the ≤16 ms / <1% pass bars. Frame-stats overlay: Settings switch, offered in debug/profile only — the engine has no frame timeline in a release build, so real-device frame stats come from `flutter run --profile` (documented).
- C2: DONE — `VisualQuality` Auto/High/Low in Settings; `core/visual_quality.dart` holds the sustained-jank monitor (rolling ~10 s window, >1 % of frames over 16.7 ms flips Auto to Low, no recovery by design) and the tier resolver. Low thins blur (`Tokens.reducedBlurFactor`), freezes backdrop drift, and solidifies GlassSurface. Auto engages on measured jank; a preset Low is the explicit full fallback.
- C3: DONE — exactly one `BackdropFilter` site remains (glass_surface.dart); each ambient blob is its own `RepaintBoundary`, so gradient raster work is cached per blob between drift eases.

### Deliberately not implemented (with reasons)
- **↑/↓ volume keys.** The app has no own volume model — playback follows the OS mixer, and no volume surface exists anywhere in the spec. A keyboard control that adjusts nothing real would be a phantom control, which design.md section H forbids.
- **"Add to playlist".** The sidecar exposes read-only playlist endpoints (`GET /library/playlists`, `GET /playlist/{id}`) — no add/modify API exists, and `lib/ui/context_menu.dart`'s policy is to never show a menu entry the app cannot perform.
- **Artwork hero "into Now Playing".** Now Playing is a `StatefulShellRoute` branch, not a pushed route; branch switches create no hero flight. The equivalent flight that *is* real — Home card → collection page — is implemented; Now Playing's art intentionally carries no hero tag so it can never collide with a card's tag on the shared shell route.
- **OS Snap-layouts flyout.** Windows only shows it over a native caption button; with `TitleBarStyle.hidden` it cannot appear. The app offers the same docking through its own menu (see item 2 above).

### Needs a real device
- Jank-tier behavior on a physical Android device (monitor thresholds are tuned on the desktop harness).
- Snap left/right docking (user32 metrics + dpr conversion) on multi-monitor, mixed-DPI Windows setups.
- Mica fallback appearance on Windows 10 (the in-app side is covered by tokens; the native material itself cannot be verified here).
