# DESIGN_TOKENS.md

Visual spec for the WinUI 3 frontend. Approved via mockup — do not deviate without checking
back. Two reference mockups exist: Home (hero + recommended + popular rail) and Now Playing
(fan carousel + ambient glow). Every other screen (Search, Library, EQ panel) follows these
same tokens.

## Core principle
Pitch black by default. Color appears only from real album art and one fixed accent — never
from decorative gradients, mesh backgrounds, or unrelated color washes. Glass/blur is reserved
for floating chrome (tab bar, mini player, Now Playing transport pill) — content itself stays
flat black, not boxed in bordered cards everywhere.

## Colors
```
--accent: #FA2D48        (single accent — active/interactive states ONLY: playing track,
                           progress fill, liked heart, active nav icon. Never decorative.)
--bg: #000000             (page background, always true black, never dark gray)
--glass: rgba(255,255,255,0.06)         (tab bar / standard chrome)
--glass-strong: rgba(255,255,255,0.10)  (mini player / floating pill)
--border: rgba(255,255,255,0.10)
--border-strong: rgba(255,255,255,0.16)
--text-primary: #FFFFFF
--text-secondary: rgba(255,255,255,0.55)
--text-muted: rgba(255,255,255,0.32)
```
Album art / tile gradients: rich, deliberate 2-stop diagonal gradients (160deg), one per
tile, e.g. `#E8935A → #4A2418` (amber), `#7C6BC4 → #211A3B` (violet), `#3E8E7E → #16302A`
(teal), `#4F8FC4 → #0E1B29` (blue), `#D4667A → #3B1620` (rose). Never a single flat gray box,
never a rainbow/mesh wash across multiple elements.

## Typography
Font: `'Segoe UI Variable Display', 'Segoe UI Variable Text', 'Segoe UI', system-ui, sans-serif`
Two weights only: 400 (body/secondary) and 500/600/700 (headings/emphasis) — bold and
confident, not muted small-caps labels.
- Page headline (e.g. "Good evening"): 26–30px / 700, letter-spacing -0.3 to -0.5px
- Section header (e.g. "Recommended for you"): 17–19px / 600
- Card/row title: 13–14px / 500
- Secondary/subtitle text: 12–13px / 400, `--text-secondary` or `--text-muted`
Sentence case everywhere. No all-caps labels, no tracked-out eyebrow text above headings.

## Glass / chrome treatment
Applies ONLY to: top titlebar+tab bar, mini player (docked views), Now Playing transport pill.
```
background: var(--glass) or var(--glass-strong)
backdrop-filter: blur(40–46px) saturate(180–200%)
border: 1px solid var(--border) or var(--border-strong)
```
Floating pills (mini player, Now Playing transport) additionally get a specular highlight —
a diagonal light streak, NOT a colored glow:
```css
.player::before {
  content: ''; position: absolute; top: -40%; left: -10%; width: 60%; height: 140%;
  background: linear-gradient(120deg, rgba(255,255,255,0.16), transparent 60%);
  transform: rotate(-8deg); pointer-events: none;
}
```

## Icons
Real inline SVG, thin stroke (1.8px, round caps/joins) or filled glyphs — never unicode
characters (◁▷⟲⇄ etc.) standing in for icons. Reference set already built: shuffle, prev,
play (filled circle button, black-on-white), next, repeat, heart (like), lyrics/lines, queue,
cast, EQ/volume bars. Reuse these exact paths across screens rather than inventing new icon
styles per screen.

## Navigation
Top tab bar merged into the title bar, styled as a pill segmented control (rounded capsule,
active tab = white bg + black text, inactive = transparent + `--text-secondary`). Real
Windows caption buttons (– ▢ ×) at the top-right, drawn as thin-stroke SVG, not emoji or
web-style X. Tabs: Home | Search | Library | Now Playing.

## Screen-specific notes

### Home
Two-column content: main column (hero banner + "Recommended for you" tile row) + fixed-width
(~250px) "Popular" rail on the right. Hero banner: glass card, album art tile (176px) +
title/artist/Play+Follow pill buttons + listener count. Recommended tiles: 108px square art,
title/subtitle below, no card border around the tile itself — art speaks for itself.

### Now Playing
3D fan carousel of queue (prev/next tracks scaled down, rotated via `perspective` +
`rotateY`, faded to ~35–60% opacity; current track centered, largest, full opacity).
Ambient background blur is generated FROM the current track's own art gradient colors
(radial-gradient blurred ~90px, opacity ~0.55, dark overlay on top for legibility) — never
an unrelated decorative palette. Big bold title/artist below carousel, action icon row
(like/lyrics/queue), then the floating transport pill.

### Not yet mocked — build to these tokens when the time comes
Search, Library, Lyrics view (toggle state within Now Playing), EQ panel. Use the same
glass/color/type rules above; check back before introducing anything not covered here
(e.g. a new color, a new corner-radius value, a different icon stroke weight).