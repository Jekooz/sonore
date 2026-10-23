import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_settings.dart';

/// Which tier the glass recipe actually renders, after the user's
/// [VisualQuality] preference resolves.
enum VisualQualityTier { high, low }

/// The sustained-jank detector behind `VisualQuality: Auto`.
///
/// Frame timings arrive from the engine's own callback. A rolling window of
/// [JankMonitor.windowFrames] frames where more than [JankMonitor.jankShareThreshold]
/// ran past the 60 Hz budget (16.7 ms) flips [jankDetectedProvider] to true.
/// There is no recovery by design: a bouncing threshold would toggle the glass
/// recipe — and every surface derived from it — faster than any user could
/// follow. Moving the Settings control wins either way.
///
/// The window is ~10 s of frames at 60 Hz, so a single heavy scroll or route
/// change (which produces a handful of slow frames at worst) never triggers,
/// but a sustained failing pattern does.
final NotifierProvider<JankMonitor, bool> jankDetectedProvider =
    NotifierProvider<JankMonitor, bool>(JankMonitor.new);

class JankMonitor extends Notifier<bool> {
  /// Evaluated frames before jank is measured anew.
  static const int windowFrames = 600;

  /// The pass bar from docs/PERF_CHECKLIST.md: under 1% dropped frames.
  static const double jankShareThreshold = 0.01;

  /// The frame budget on a 60 Hz display; the resolver does not need to know
  /// a device's refresh rate — slower budgets self-report through the same
  /// rule, erring toward the cheaper recipe.
  static const Duration frameBudget = Duration(milliseconds: 17);

  int _frames = 0;
  int _slow = 0;

  @override
  bool build() {
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    ref.onDispose(_detach);
    return false;
  }

  void _detach() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
  }

  void _onTimings(List<FrameTiming> timings) {
    if (state) return; // already degraded; nothing left to bookkeep
    for (final FrameTiming timing in timings) {
      // A frame is slow when either its build or its raster pass blew the
      // budget — what DevTools reports as UI thread and raster thread times.
      final Duration frameTime = timing.buildDuration > timing.rasterDuration
          ? timing.buildDuration
          : timing.rasterDuration;
      _frames++;
      if (frameTime > frameBudget) _slow++;
    }
    if (_frames < windowFrames) return;
    final double rate = _slow / _frames;
    _reset();
    if (rate > jankShareThreshold) {
      state = true;
    }
  }

  void _reset() {
    _frames = 0;
    _slow = 0;
  }
}

/// The tier the glass and ambient layers watch.
///
/// Auto resolves High until the monitor reports sustained jank; High and Low
/// pin the recipe regardless (Low is the explicit trade: thin blur, frozen
/// backdrop, solid surfaces).
final NotifierProvider<VisualQualityResolver, VisualQualityTier>
visualQualityProvider =
    NotifierProvider<VisualQualityResolver, VisualQualityTier>(
      VisualQualityResolver.new,
    );

class VisualQualityResolver extends Notifier<VisualQualityTier> {
  @override
  VisualQualityTier build() {
    final VisualQuality requested = ref.watch(
      appSettingsProvider.select(
        (AppSettings settings) => settings.visualQuality,
      ),
    );
    return switch (requested) {
      VisualQuality.low => VisualQualityTier.low,
      VisualQuality.high => VisualQualityTier.high,
      VisualQuality.auto =>
        ref.watch(jankDetectedProvider)
            ? VisualQualityTier.low
            : VisualQualityTier.high,
    };
  }
}
