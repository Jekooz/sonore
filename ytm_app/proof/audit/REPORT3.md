# Round 3 — final report

Branch `ui/polish-pass`, monochrome FULL GLASS + MINIMAL. ~20 commits this round, unpushed.
Full evidence: `proof/audit/ROUND3.md` (audit → per-item after-state), `docs/PERF_CHECKLIST.md`,
`docs/screenshots/{before,after}`.

## DONE (round-1 items 1–10 + round-2 leftovers)

- **A1** — Playlist header keeps title + actions on one row at 390 and 800 (icon-only fallback tiers, square 48 px pills).
- **A2** — Shared `ContentColumn`; Library, collection pages and Queue now sit in the centered content column.
- **1 Window material** — Reduce transparency / OS high contrast swaps Mica for a solid fill, live and at boot.
- **2 Title bar** — Snap left/right + maximize/restore menu on the maximize button (user32 work area via dart:ffi).
- **4 Tokens** — All audited stray numbers tokenized (`menuWidth`, live-badge micro geometry, lyric skeleton).
- **5 States** — Equalizer error retry; designed loaders replace the two raw spinners.
- **6 Keyboard** — Every `Pressable` is focusable with Enter/Space activation and a keyboard-only focus ring; hardware media keys answer globally.
- **7 Search** — Recent queries persist across launches; results walk with the arrow keys.
- **8 Motion** — 200 ms fade+rise page transitions (Reduce Motion → 150 ms cross-fade); artwork Hero flight card → collection page.
- **9 A11y** — Tokenized solid tooltips; caption-contrast on user content swept to subtitle contrast.
- **10 Reduce transparency** — Tooltips solid, window material follows the preference, low-end engage via the tier.
- **C1** — Release APK built; frame-stats overlay (debug/profile only); `docs/PERF_CHECKLIST.md`.
- **C2** — Visual quality Auto/High/Low: sustained-jank monitor (>1 % of a ~10 s window over 16.7 ms → Low), thinned blur, frozen drift, solid recipe.
- **C3** — One `BackdropFilter` site total; ambient blobs raster-cached per blob (`RepaintBoundary`).

## Fixed during verification
Settings switches scroll into view in the write-through test; goldens regenerated only for intentional
changes (specimen pills, home/library tablet blobs, desktop collection/queue/library columns, settings panel),
all tests green: **flutter analyze clean, 385/385, pytest 192/192**, 36 screens re-captured + inspected
(playlist 390 one-row header, Library centered at 1920, new Settings rows, solid reduce-transparency surfaces).

## Not implemented (deliberate, documented in ROUND3.md)
- **↑/↓ volume keys** — there is no in-app volume model to move; the app follows the OS mixer (no phantom controls, per spec section H).
- **"Add to playlist"** — the sidecar exposes read-only playlist endpoints; the menu policy forbids unperformable entries.
- **Hero into Now Playing** — Now Playing is a shell branch, not a pushed route, so no flight can trigger; the real flight (card → collection page) is implemented.
- **OS Snap-layouts flyout** — impossible over `TitleBarStyle.hidden`; the app's own snap menu covers the same result.

## Needs a real device
- Jank thresholds / Visual-quality Auto flip on physical Android.
- Snap-dock correctness on multi-monitor, mixed-DPI Windows (dpr conversion is single-view).
- Windows 10 Mica fallback appearance (native side only).
