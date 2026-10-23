# UI polish pass — round 2 report

Branch `ui/polish-pass`, unpushed. Screenshots: `proof/audit/{before,after}` and mirrored in
`docs/screenshots/{before,after}` (9 screens × 4 sizes: 1920×1080, 1280×800, 800×600, 390×844,
including Library, Playlist and Sign-in, plus a reduce-transparency sweep).

## Fixed

1. **Hero glass** — hero sits on the regular glass tier; backdrop blobs calm, neutral and never
   bleed past the hero's own silhouette.
2. **Nav selection + glow bleed** — active destination is a thick-glass pill with a hairline rim
   (side embedded in the shape); inactive pills get glass fills on hover/rest stops; glow no
   longer escapes the bar.
3. **Backdrop blobs** — calm neutral set, pulled up from the very bottom edge
   (`ambientBottomCalm`); on the mini-player pages the bottom stays quiet.
4. **Scroll under the bar** — content genuinely runs under the player bar; bottom fade masks +
   shell-owned `ShellClearance` replace hard stop-padding; mini player persists on Queue and
   Equalizer so controls always exist.
5. **Player bar padding/scrubber/time** — inset thumb gap, past-progress corner line, compact
   scrubber thickness tokens, brighter time readouts.
6. **Popular durations + thin rails** — duration column shows all-or-none (a shelf with any
   missing duration shows none); shelves under 3 items don't render (`minRailItems`); trailing
   card fade on every rail.
7. **Settings restructure** — plain `ScreenHeader` on one `formMaxWidth` column (back arrow on the
   column edge), every section grouped into glass panels, "Theme: dark" filler note deleted,
   helper text/notes/save-status moved from `caption` to `subtitle` (≥4.5:1).
8. **Visible controls** — switches and sliders get a visible rest state (light translucent track +
   hairline rim via `SwitchTheme`, `controlTrackRest`), sliders share one `sliderGlass` theme at
   seek-bar line weight, text-size slider signed with A…A glyphs and the chosen %, EQ band/dB
   labels readable.
9. **Equalizer page** — header aligned to the Settings form column, flat-and-off shape reads
   "Flat" (not "Custom"), the whole shape panel dims to 45% and turns inert while the EQ is off,
   "Reset to flat" lives inside the shape panel, summary correctly says "Off".
10. **Now Playing** — art gap widened (s32), seek/transport/secondary actions sized to the
    rendered artwork width (post-frame measured via a `ValueNotifier`, floored at
    `TransportPill.minWidth` so a 320px phone never overflows), lyrics affordance is a quotation
    mark (`quotes`), tooltips verified on the secondary actions.
11. **Search "…" affordance** — full-text-contrast dots, hover glass fill + hairline rim, tooltip.
12. **State pages equivalent fixes** — `StateMessage` footnotes (Sign-in, Offline, Error, Empty,
    Signed-out) were dim `caption` running corner-to-corner on wide windows; now `subtitle` on
    the measured form column. Playlist header `…` wrapping to its own centered line on narrow
    windows checked against the before shots — identical, pre-existing, left alone.

## Unfixed (deliberate)

- Playlist/album header `…` lands on its own line on narrow widths — pre-existing wrap behavior,
  unchanged in this pass; flag for round 3 if the header row should break differently.
- Library rows hug the page margin at 1920 while Search centers a ~1180px column — pre-existing
  layout difference, not touched in this polish scope.
- 23 + 4 golden images regenerated — intentional, matches items above.

## Verification

- `flutter analyze`: clean (0 issues) after every commit.
- Behavioral tests: 385 passing, 0 behavioral failures. Goldens updated twice, both reviewed.
- `pytest tests`: 192 passed (1 deprecation warning from starlette/httpx, informational).
- Screenshot audit: 36 after-shots at all four sizes; every screen inspected against before.
- Extra regression found and fixed during review: the art-width coupling overflowed the
  `TransportPill` Row on a 320px phone (89px → 32px → 0 after flooring the player column at the
  pill's real width, incl. both padding layers); confirmed by throwaway probe at 320×640, probe
  deleted.

## Performance notes

- `GlassSurface` remains the **single `BackdropFilter` owner** — no new blur layers added; the
  settings panels reuse one glass widget per section, equal in count to the old sections' separate
  chrome plus margin.
- The two "after" audit runs both completed in ~13–27s, same order as the "before" run — no
  measurable build-time regression from the panels/notifier.
- The new `ValueNotifier`/post-frame callback in the Now Playing column adds one post-frame
  callback per artwork relayout and a rebuild of the controls subtree only when the rendered art
  size actually changes (guarded by a value check); it does not rebuild during layout.
- `AnimatedOpacity` on the EQ shape uses the existing fade duration token and obeys
  `MediaQuery.disableAnimations` / reduce-motion.
- No dependency, token-asset or image changes beyond 4 bytes of icon font codepoint usage; nothing
  pushed.
