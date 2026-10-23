# Performance checklist — real-device runs

The release APK lives at `build/app/outputs/flutter-apk/app-release.apk`
(`flutter build apk --release`). Install it, or run
`flutter run --profile` for frame stats; **the engine publishes no frame
timeline in a release/signed build**, so the frame-stats overlay
(Settings → Appearance → "Show frame stats", offered outside release builds)
only shows real numbers from a debug or profile run of the same tree.

## What to read

- The frame-stats overlay: the two stick charts are the **UI thread** (build)
  and **raster thread** times; anything above the frame budget (~16.7 ms on a
  60 Hz screen) was a dropped frame.
- DevTools → Enhance tracing if you want exact per-frame numbers
  (`flutter run --profile`, then open DevTools from the run).
- The Visual quality row (Settings → Appearance). On `Auto`, a sustained
  window with more than 1% of frames over 16.7 ms thins blur and freezes the
  backdrop drift on its own; `Low` pins that state.

## Scenarios (run each for ~2 minutes, note worst frame)

1. **Scroll Home** — both rails, fast flick, then slowly to the page bottom.
2. **Scroll Search** — typing a query, then scrolling the grouped results.
3. **Open/close the Queue screen** — the reorderable list plus reuse of the
   rows is the heaviest route change; repeat 10 times.
4. **Track change cross-fade** — skip between 3–4 tracks and watch the
   ambient layer cross-fade (600 ms) while scrolling.
5. **Now Playing for 2 minutes** — lyrics following playback, artifacts over
   the veil, no scrolling: it must sit idle-cost at zero.

## Pass bar

- Worst **UI (build)** frame time ≤ 16 ms.
- Worst **raster** frame time ≤ 16 ms.
- Dropped frames: **under 1%** of a sustained 10 s window (the same rule the
  Auto quality tier measures itself against).
- Visual quality Auto must **not** flip to Low during any pass scenario; if
  it does, the scenario fails.
