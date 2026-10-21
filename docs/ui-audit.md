# UI audit — pre-glass pass (branch ui/polish-pass)

Rendered with the deterministic audit harness (`test/visual_audit/audit_shots_test.dart`,
fake artwork, fixed palette) — 8 screens x 4 widths (1920x1080, 1280x800, 800x600, 390x844),
32 shots in `proof/audit/before/`. Nothing below is inferred from code alone; each item
names where it is visible.

## High — blocks the new direction

- **H1 · Accent red everywhere chrome is.** `#FA2D48` is the active color on the nav pill/tab
  bar (home_wide, search_wide), progress lines (every logged screen), hero Play (home_*),
  Queue/Playlist pills (`now_playing_*`), sliders and switches (`settings_desktop`,
  `equalizer_narrow`), playing-row titles and the liked heart. The glass spec is monochrome
  chrome — every one of these fails it.
- **H2 · Hard true-black app background.** `Scaffold` is `#000000` on every screen; only Now
  Playing carries an artwork wash (`home_wide`, `library_*`, `search_*` show dead black).
  Spec: one app-wide ambient layer derived from artwork, with a neutral gradient when idle.
- **H3 · Now Playing ambient is the worst perf case in the app.** `AmbientBackground` paints
  three full-viewport blobs then an `ImageFilter.blur(sigma 90)` over the whole screen — a
  full-screen blur filter on the heaviest page, and it coexists with up to three `GlassSurface`
  blurs on other pages. Must become cheap radial gradients in one `RepaintBoundary`.

## Medium

- **M1 · One glass recipe, no tiers.** `GlassSurface` has a single fill (blur 30 / white 8%).
  List rows, search field, queue panel, Up Next panel, settings switches/sliders are flat
  opaque or bare fills (`search_wide`, `here the queue panel on now_playing_wide`,
  `settings_desktop`). Spec needs thin/regular/thick tiers routed through the one widget.
- **M2 · Windows window is plain black.** No Mica/Acrylic, no frameless native feel; the custom
  title bar floats over flat black. Spec: native window material under the in-app backdrop.
- **M3 · Hero legibility depends on artwork.** `heroTintOpacity 0.45` washes the hero without
  a guaranteed text scrim; with bright art the title can drop under 4.5:1 (`home_*`). Needs an
  adaptive scrim spec'd for text.
- **M4 · No content max width.** At 1920 the rails, hero and Popular list stretch edge to edge
  (`home_wide`, `search_wide` line lengths ~1900px). Ultrawide needs a readable max width.
- **M5 · Now Playing carousel mis-centred at 800x600 / 390x844.** Only the right neighbour
  peeks; the left edge is empty (`now_playing_narrow`, `now_playing_phone`).
- **M6 · Dialogs/menus/sheets not in the glass system.** Context menu has its own recipe
  (44px rows, r12) detached from `GlassSurface` tiers.
- **M7 · No grain/noise over the base.** Flat `#08080C`-style gradients will band; spec asks
  for a faint grain overlay.

## Low

- **L1 · Artwork placeholders are flat `#141417` squares** (`home_*` tiles); glass-tinted
  placeholder would sit better under the new backdrop.
- **L2 · Settings "engine 2024.08.06 (bundled)" row is clipped mid-render at 1280x800** right
  above the NP bar — scrollable (not a bug), but the settings page has no bottom breathing
  room above a docked NP bar.
- **L3 · Settings/equalizer sliders run the full content width on desktop** (thumb travel
  ~1900px on the text-size slider at `settings_desktop`).

## What was already fine (checked, not padded)

- Loading/empty/error/offline/signed-out states exist as real designed screens
  (`state_*` goldens cover them); no raw error text anywhere in the 32 shots.
- Phone touch targets and the floating nav pill + docked NP bar are correct on phone layout;
  chips and rows ellip cleanly (`library_phone`, `search_phone`).
- Popular rail present on wide, absent on phone (as spec'd).
- No overflow/pixel errors in any of the 32 shots.
