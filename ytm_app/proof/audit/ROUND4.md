# Round 4 audit — UI polish pass (FULL GLASS + MINIMAL)

Branch `ui/polish-pass`, monochrome FULL GLASS + MINIMAL. Seven tasks, unpushed.
Paths relative to `ytm_app/`. Round 3 files (`ROUND3.md`, `REPORT3.md`) untouched.

| # | Item | Verdict before | Fix after |
|---|------|----------------|-----------|
| 1 | Now Playing landscape two-column | MISSING — NP was always one stacked column; at 800x600 the artwork crushed the controls toward the chrome. | DONE — `_PlayerColumn` splits into `_buildPortrait`/`_buildLandscape` (`now_playing_screen.dart`). The condition reads the window (`MediaQuery.sizeOf`: ratio > 1.3 and height ≤ 700), not the column. Art is as large as the height allows (32px band above the floating chrome); the right column is vertically centered — title, artist, scrubber (spans the column), transport, icon row. Tests: no-overflow/no-scroll at 1920 / 1280 / 800x600 / 390 / 320, plus the two-column geometry assertions at 800x600 with text scale 1.3. |
| 2 | Library row polish | PARTIAL — a row without a subtitle still rendered `Text('')`, claiming a phantom second line and pushing the title off center; the filter chips sat flush against the first row. | DONE — `TrackRow` omits the empty-subtitle `Text` (true centering, unit-tested); Library `ListView` top padding `s12` gives the chips-to-list gap. |
| 3 | Collection column alignment | PARTIAL — the back arrow lived *outside* `ContentColumn` with a one-off `left: s8` offset, so it hugged the window edge while the content centered 20px in at 1280. | DONE — back row rides inside the shared column (`collection_screen.dart`), inset by `Tokens.pageMargin` vertically padded `s8`, `Align(centerLeft)`; no one-off offset stays. Whole-page realignment visible in the re-captured album/context-menu shots. |
| 4 | Phone tab bar polish | PARTIAL — the selected pill could kiss the glass rim, the "…" settings slot was a ~24px-wide hit, and "Now Playing" clipped on narrowest widths. | DONE — nav row keeps a horizontal `s8` inset (`nav_bottom_bar.dart`); `_NavAction` is 48dp × 48dp (vertical+horizontal `s12`); destinations carry a `shortLabel` ('Playing') shown when width ≤ 400, tooltips/semantics keep the full name; shell test covers short labels, rim clearance and the 48dp target (InkWell-ancestor geometry, not semantics finders). |
| 5 | Settings trim + segmented control | PARTIAL — helper texts ran 2–4 lines; visual-quality choices were hollow outline chips; the frame-stats write was only hidden by an `if (!kReleaseMode)` on the row. | DONE — every helper/subtitle/note copy is ≤ 1 line; `_ChoiceChip` rest state = `Tokens.controlTrackRest` fill + hairline rim, selected = solid `Tokens.text` with `Tokens.bg` text (test reads `AnimatedContainer.decoration`); `AppSettingsNotifier.setShowPerformanceOverlay` refuses release builds (`kReleaseMode` early return + assert), so a release binary cannot commit it. |
| 6 | Multi-hue ambient backdrop | PARTIAL — the lift took 3 population-ordered colors; a mono-hue artwork yielded one flat wash and the top-right / bottom-left corners stayed dead black. | DONE — `Tokens.diversifyAmbientHues` bands hues at ~30° resolution; a single-band palette gains two analogous tones (+32°, −48° with a lightness dip 0.68); `ambientPlacements` extends to 5 lanes (top-right, bottom-left added), `ambientMaxBlobs = 5`. Production `_loadAmbientPalette` wraps the lift with it; the first three anchors/order are untouched, so test palettes (3 colors) render identically and no unrelated golden churns. Multicolor proof: pinned `kMulticolorFixtureUrl` (lagoon variant) + new audit captures `home_multicolor_desktop`, `now_playing_multicolor_desktop`, `now_playing_multicolor_narrow`. |
| 7 | Verification + re-capture | — | DONE — the 15 golden diffs from the pass were inspected individually (nav-bar label/inset on all 390-wide composites; 12px library gap + row centering; collection back-row whole-page shift) and only then regenerated; stale `test/golden/failures/` artifacts removed; stray untracked `docs/screenshots/after/now_playing_narrow_800x600.7z` deleted; all screens re-captured (39 shots incl. the 3 multicolor fixtures) and compared against before. |

## Test helper note

`scrollSettingsTo` now drives the scroll position (sweep down through the extent, then up) instead of
gesture-dragging the list: a drag whose finger lands on a `TokenField`/`TextField` scrolls that field,
not the page, and the list's `maxScrollExtent` also grows only as distant content builds. Deterministic
for every below-fold target.

## Deliberate, documented choices

- **Landscape art bleeds to the left window edge.** The art column is sized by height on purpose; a
  full-bleed cover reads as intentional next to the centered right column, and inner margins would only
  shrink the cover.
- **Synthesis is unit-tested, not golden-tested.** The production loader runs `PaletteGenerator` over a
  network-decoded image; widget tests override the loader, so the multi-hue property is proven by the
  pinned fixture captures and the `Ambient hue synthesis` unit tests (mono → 5 colors / ≥3 hue bands,
  multi-hue passthrough, empty stays empty).
- The audit's "narrow" width is 800x600, so `now_playing_narrow` now legitimately shows the new
  landscape layout.

## Not implemented (nothing outstanding from the round-4 list)

None — all seven items fixed in place.

## Needs a real device

- Appearance of the synthesized tones under production `PaletteGenerator` on real (network-fetched,
  GPU-decoded) artwork — the fixture captures use the deterministic sample resolver.
- Everything still listed in `REPORT3.md` (jank thresholds / Visual-quality Auto on physical Android,
  snap-dock on multi-monitor mixed-DPI, Win10 Mica fallback).
