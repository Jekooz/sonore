# UI audit — glass pass (branch ui/polish-pass)

Two rounds, both rendered with the deterministic audit harness
(`test/visual_audit/audit_shots_test.dart`, fake artwork, fixed palette):

- **Before** — 32 shots in `proof/audit/before/` (8 screens x 4 widths), taken at the start of the
  pass. The defect list below was written from those shots only.
- **After** — 36 shots in `proof/audit/after/` (same screens x 4 widths, plus Reduce-Transparency
  variants), taken after the rebuild. Nothing below is inferred from code alone; each item names
  where it is visible.

## Before-round defects → after-round status

### High

| # | Defect (visible in) | After round |
| --- | --- | --- |
| H1 | Accent red on chrome: nav pills, progress lines, hero Play, pills, sliders, switches, playing titles, liked heart (`home_*`, `search_*`, `settings_*`, `equalizer_*`) | **Fixed.** Every control is monochrome: white fills, raised tint pills (`reduce_transparency_*`, `search_desktop`, `settings_desktop` show the settled state). |
| H2 | Hard true-black background everywhere (`home_*`, `library_*`) | **Fixed.** One artwork-derived ambient layer behind everything (`*_phone`, `*_desktop` show the palette wash; idle is neutral). |
| H3 | Full-screen `ImageFilter.blur` ambient on Now Playing | **Fixed.** Ambient is cheap radial gradients in one `RepaintBoundary`; `BackdropFilter` exists only inside `GlassSurface` (checked `tool/check_tokens.ps1` — remaining matches are its known `AppIcons.`/path false positives). |

### Medium

| # | Defect | After round |
| --- | --- | --- |
| M1 | One glass recipe, no tiers | **Fixed.** `GlassSurface` owns thin/regular/thick tiers; rows, panels, sheets, menus and inputs route through it (`search_desktop` search field, `now_playing_desktop` panels). |
| M2 | Plain black Windows window | **Fixed earlier** (Windows Mica backdrop; commit history). |
| M3 | Hero legibility depends on artwork | **Fixed.** Text scrim guarantees contrast over the art tint (`home_desktop`). |
| M4 | No content max width at 1920 | **Fixed.** `contentMaxWidth` caps shelf/hero width; form pages cap at `formMaxWidth`, centred (`equalizer_wide`, `settings_wide`). |
| M5 | Now Playing carousel mis-centred at narrow widths | **Fixed.** The carousel is gone: Now Playing is a single centred column with an on-demand queue/lyrics panel (`now_playing_narrow`, `now_playing_phone`). |
| M6 | Dialogs/menus detached from the glass system | **Fixed** (context menu routes through `GlassSurface` tiers). |
| M7 | No grain over the base | **Fixed** (seeded grain layer in the ambient recipe). |

### Low

| # | Defect | After round |
| --- | --- | --- |
| L1 | Flat `#141417` artwork placeholders | **Fixed** (glass-tinted placeholder). |
| L2 | Settings content runs to the docked bar with no breathing room | **Fixed.** The shell computes one bottom inset from the floating chrome; no page ever clears it manually (`library_mini_phone`, `settings_desktop`). |
| L3 | Sliders run the full content width on desktop | **Fixed** (`formControlMaxWidth` on settings; EQ capped at `formMaxWidth`). |

## What the rebuild changed since the before round

- **Now Playing**: single-column rebuild — large artwork, centred metadata, `transportMaxWidth`
  seek row, transport pill, icon-only secondary actions; queue and lyrics open as on-demand panels
  (desktop right glass panel, phone bottom glass sheet with a visible grip that flings away). The
  queue carousel is deleted.
- **Shell**: the Now Playing bar is floating chrome — the same thick-glass pill as the nav — with a
  real thin interactive scrubber along its bottom edge; phone gets the two floating layers
  (mini player above the nav pill) with computed content insets.
- **Nav**: selected tabs get a raised pill on both bars; Settings lights on its own pages
  (`/now-playing/equalizer` included) and never leaves a destination lit at the same time.
- **Rows**: TrackRow carries hover/pressed/focus fills and the animated live badge (gated by the
  ambient-motion flag, Reduce Motion and the paused state, so `pumpAndSettle` stays honest).
- **Queue/Equalizer/Settings**: page-gutter rule shared by every screen; queue rows land on it; EQ
  redesigned into two glass panels with dB labels and the preset shown next to the switch.

## Verification for this round

- `flutter analyze` clean; `flutter test` 385 passed (widget + golden).
- `pytest D:\ytm-client\tests` 192 passed.
- Full golden set re-rendered and eyeballed; shell goldens include the phone mini-player case
  (`shell_library_mini_phone_390x844`).
- Reduce-Transparency fallback captured at all four widths (`reduce_transparency_*`) — solid
  palette-tinted fills, same geometry, overheads unchanged.
