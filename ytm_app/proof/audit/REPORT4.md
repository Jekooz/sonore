# Round 4 — final report

Branch `ui/polish-pass`, FULL GLASS + MINIMAL. 11 commits this round, unpushed.
Full evidence: `proof/audit/ROUND4.md`, `docs/screenshots/{before,after}` (39 shots).

## DONE (7/7 items)

- **R1 Now Playing landscape** — short, wide windows (ratio > 1.3, height ≤ 700) render two columns:
  artwork left, sized by height with a 32px band above the chrome; controls right, vertically centered;
  the scrubber spans the right column. No-overflow audited at 1920 / 1280 / 800x600 / 390 / 320 and at
  1.3 text scale.
- **R2 Library rows** — rows without a subtitle truly center their title (the phantom empty-subtitle
  line is gone); a 12px gap now separates the filter chips from the list.
- **R3 Collection alignment** — the back arrow moved inside the shared `ContentColumn`, inset by the
  same page margin as the header art and rows; the one-off window-edge offset is gone (whole-page
  realignment at 1280).
- **R4 Phone tab bar** — the selected pill never touches the glass rim (row inset `s8`); the "…"
  settings slot is a real 48dp target; at ≤ 400px the bar shows "Playing" so labels stay single-line
  (semantics keep "Now Playing").
- **R5 Settings** — every helper text is one line; Visual quality is a proper segmented control
  (~10% white rest fill + rim, solid-white selection); the frame-stats write is compile-time removed
  from release builds (`kReleaseMode` gate in the notifier, not just the row).
- **R6 Backdrop hues** — a single-hue lifted palette gains two analogous tones (+32°/−48°, darkened)
  painted on new top-right / bottom-right / top-left blob lanes, so no screen edge sits flat black
  while playing multi-window-sized artwork; genuinely multi-hue palettes pass through untouched.
  First three lanes/order unchanged, so untouched palettes render identically.
- **R7 Verification** — `flutter analyze` clean, flutter tests 393/393, pytest 192/192; the 15 changed
  goldens were each diff-inspected as intentional before regenerating (phone bar label/inset, library
  gap/centering, collection back-row shift); all screens re-captured at 1920 / 1280 / 800 / 390 plus
  reduce transparency (+3 pinned multicolor-fixture captures) and reviewed against `before`. Stray
  untracked `now_playing_narrow_800x600.7z` deleted.

## Fixed during verification

- Two new nav-bar/Now Playing test finders avoided `bySemanticsLabel` (unreliable without an ensured
  semantics handle here) in favour of InkWell-ancestor geometry.
- The settings scroll helper (`scrollSettingsTo`) now drives the scroll position — gesture drags
  stalled on text fields that scroll themselves. All settings write-through tests pass with it.

## Not implemented

Nothing from the round-4 list remains open.

## Needs a real device

- The production `PaletteGenerator` path (network-decoded artwork) behind the hue synthesis — the
  captures use the deterministic sample resolver; real-device tuning of the resting tones is manual.
- Carried from round 3: jank thresholds / Visual-quality Auto flip on physical Android, snap-dock
  correctness on multi-monitor mixed-DPI Windows, Win10 Mica fallback appearance.
