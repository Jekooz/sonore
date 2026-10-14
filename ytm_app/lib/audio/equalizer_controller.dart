import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_settings.dart';
import 'equalizer.dart';
import 'playback_engine.dart';
import 'playback_service.dart';

/// What the equalizer is doing right now: the configuration the user asked for,
/// whether the engine accepted it, and what the engine says it now holds.
///
/// [appliedFilter] is the evidence half. It is read straight back from the
/// engine after every change, so a screen (and a test) can prove the control
/// changed the real processing configuration instead of assuming it did.
@immutable
class EqualizerState {
  const EqualizerState({
    required this.config,
    this.isApplying = false,
    this.error,
    this.appliedFilter,
  });

  final EqualizerConfig config;
  final bool isApplying;

  /// The last failure to write to the engine, phrased for a user. Null when
  /// the engine accepted the configuration.
  final String? error;

  /// The filter the engine reports it holds. Null when the engine cannot be
  /// asked, which is not the same as "applied".
  final String? appliedFilter;

  EqualizerState copyWith({
    EqualizerConfig? config,
    bool? isApplying,
    Object? error = _sentinel,
    Object? appliedFilter = _sentinel,
  }) {
    return EqualizerState(
      config: config ?? this.config,
      isApplying: isApplying ?? this.isApplying,
      error: identical(error, _sentinel) ? this.error : error as String?,
      appliedFilter: identical(appliedFilter, _sentinel)
          ? this.appliedFilter
          : appliedFilter as String?,
    );
  }

  static const Object _sentinel = Object();
}

/// Drives the real audio-shaping capability of the running engine.
///
/// Nothing here is decorative: every setter writes the configuration into
/// libmpv and then reads it back. Where the engine has no such capability the
/// setters report that plainly, and the Equalizer screen renders its
/// unavailable state rather than controls that do nothing.
class EqualizerController extends Notifier<EqualizerState> {
  /// Monotonic token so a slow apply from an earlier change cannot overwrite a
  /// newer one's result.
  int _epoch = 0;

  @override
  EqualizerState build() {
    // Read, do not watch: this controller persists every change into the same
    // provider, and watching it would rebuild (and reset) the state in the
    // middle of applying a change, throwing away the engine's answer.
    final EqualizerConfig initial = ref.read(appSettingsProvider).equalizer;

    ref.listen<AppSettings>(appSettingsProvider, (AppSettings? _, AppSettings next) {
      // Only an *external* change matters here (Settings -> Reset preferences).
      // The change this controller just made is already the current state.
      if (next.equalizer != state.config) _apply(next.equalizer);
    });

    return EqualizerState(config: initial);
  }

  EqualizerEngine? get _engine => ref.read(playbackEngineProvider).equalizer;

  /// Whether this engine can shape audio at all.
  bool get isSupported => _engine?.isSupported ?? false;

  /// Writes [state.config] into the engine.
  ///
  /// Called once at startup so a persisted equalizer shapes the very first
  /// track, not the first track *after* the screen has been opened. Failures
  /// land in [EqualizerState.error], never in a thrown exception.
  Future<void> applyToEngine() => _apply(state.config);

  Future<void> _apply(EqualizerConfig config) async {
    final EqualizerEngine? engine = _engine;
    final int epoch = ++_epoch;

    if (engine == null || !engine.isSupported) {
      state = state.copyWith(
        config: config,
        isApplying: false,
        error: 'This engine cannot apply an equalizer.',
      );
      _persist(config);
      return;
    }

    state = state.copyWith(config: config, isApplying: true);
    _persist(config);

    try {
      await engine.apply(config);
      final String? filter = await engine.readFilter();
      if (epoch != _epoch) return;
      state = state.copyWith(
        config: config,
        isApplying: false,
        error: null,
        appliedFilter: filter,
      );
    } catch (error) {
      if (epoch != _epoch) return;
      state = state.copyWith(
        config: config,
        isApplying: false,
        error: error is EqualizerException
            ? error.message
            : 'The equalizer could not be applied.',
      );
    }
  }

  void _persist(EqualizerConfig config) {
    // Persistence is best effort; a failure is reported on the Settings
    // status provider and must not disturb the audio that is playing.
    ref.read(appSettingsProvider.notifier).setEqualizer(config);
  }

  void setEnabled(bool value) => _apply(state.config.withEnabled(value));

  void setGain(int bandIndex, double gainDb) =>
      _apply(state.config.withGain(bandIndex, gainDb));

  void setPreset(EqualizerPreset preset) => _apply(preset.toConfig());

  /// Back to flat and off.
  void reset() => _apply(const EqualizerConfig.flat());

  /// Re-reads what the engine holds without changing anything.
  Future<void> refresh() async {
    final EqualizerEngine? engine = _engine;
    if (engine == null || !engine.isSupported) return;
    final String? filter = await engine.readFilter();
    state = state.copyWith(appliedFilter: filter);
  }
}

final NotifierProvider<EqualizerController, EqualizerState>
    equalizerControllerProvider =
    NotifierProvider<EqualizerController, EqualizerState>(
  EqualizerController.new,
);

/// Whether the running engine can shape audio at all.
///
/// This single fact decides what the Equalizer screen renders: real controls,
/// or the honest unavailable state. It is read off the engine rather than
/// assumed, so a widget test with a fake engine and the shipped app agree.
final Provider<bool> equalizerSupportedProvider = Provider<bool>((Ref ref) {
  final PlaybackEngine engine = ref.watch(playbackEngineProvider);
  return engine.equalizer?.isSupported ?? false;
});
