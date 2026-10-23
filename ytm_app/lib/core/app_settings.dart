import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/equalizer.dart';
import '../audio/playback_state.dart';
import '../theme/tokens.dart';

/// The visual quality the user allows the glass recipe to use.
///
/// Auto follows the app's own frame measurements: sustained jank drops the
/// tier to Low until it is changed. High pins the full glass recipe onto the
/// strongest setting; Low trades it down on purpose (thinner blur, a frozen
/// backdrop, solid surfaces), which is what low-end Android devices should
/// start on when Auto is not enough for them.
enum VisualQuality { auto, high, low }

/// Appearance and behaviour preferences that actually change the app.
///
/// Only settings with a real implementation live here. There is still no
/// output-device picker and no "theme" switch: v1 is dark-only and the audio
/// engine exposes no device selection, so a control for either would be
/// decorative — which design.md section H explicitly forbids.
///
/// The player modes (repeat, shuffle, autoplay) live here because design.md
/// requires them to persist and the WinUI client persisted the same three in
/// settings.json. [PlaybackController] seeds itself from them and writes every
/// change back, so the transport controls and the Settings screen cannot
/// disagree.
@immutable
class AppSettings {
  const AppSettings({
    this.reduceTransparency = false,
    this.reduceMotion = false,
    this.textScale = Tokens.textScaleDefault,
    this.lyricsAutoFollow = true,
    this.equalizer = const EqualizerConfig.flat(),
    this.repeatMode = RepeatMode.off,
    this.shuffle = false,
    this.autoplay = true,
    this.visualQuality = VisualQuality.auto,
    this.showPerformanceOverlay = false,
  });

  /// Forces glass chrome onto its opaque fallback (spec: Reduce Transparency).
  final bool reduceTransparency;

  /// Overrides motion for platforms that do not surface it through MediaQuery.
  final bool reduceMotion;

  /// The largest text scale the window allows, in
  /// [Tokens.textScaleMin, Tokens.textScaleCap].
  ///
  /// This is a ceiling, not a starting point: a fresh install starts at
  /// [Tokens.textScaleDefault] and only moves when the user moves it.
  final double textScale;

  /// Whether the Lyrics screen follows the playback position on its own.
  final bool lyricsAutoFollow;

  /// Persisted equalizer shape, re-applied to the engine at startup.
  final EqualizerConfig equalizer;

  /// Transport repeat mode (spec: cycles Off → Repeat All → Repeat One).
  final RepeatMode repeatMode;

  /// Whether playback order is shuffled (spec: "Shuffle toggle persists").
  final bool shuffle;

  /// Whether the queue refills itself with recommendations when it runs out
  /// (spec section F: "Autoplay has a visible on/off state").
  final bool autoplay;

  /// The visual quality tier (Auto / High / Low: Settings > Appearance).
  ///
  /// Where [VisualQuality.auto] resolves to, the [visualQualityProvider] in
  /// `core/visual_quality.dart` decides — High until a measured jank window
  /// says otherwise.
  final VisualQuality visualQuality;

  /// The frame-stats overlay for performance runs. Offered only by debug and
  /// profile builds (the engine supplies no frame timeline in release), so a
  /// Settings row would only ever lie in a release build.
  final bool showPerformanceOverlay;

  AppSettings copyWith({
    bool? reduceTransparency,
    bool? reduceMotion,
    double? textScale,
    bool? lyricsAutoFollow,
    EqualizerConfig? equalizer,
    RepeatMode? repeatMode,
    bool? shuffle,
    bool? autoplay,
    VisualQuality? visualQuality,
    bool? showPerformanceOverlay,
  }) {
    return AppSettings(
      reduceTransparency: reduceTransparency ?? this.reduceTransparency,
      reduceMotion: reduceMotion ?? this.reduceMotion,
      textScale: _clampScale(textScale ?? this.textScale),
      lyricsAutoFollow: lyricsAutoFollow ?? this.lyricsAutoFollow,
      equalizer: equalizer ?? this.equalizer,
      repeatMode: repeatMode ?? this.repeatMode,
      shuffle: shuffle ?? this.shuffle,
      autoplay: autoplay ?? this.autoplay,
      visualQuality: visualQuality ?? this.visualQuality,
      showPerformanceOverlay:
          showPerformanceOverlay ?? this.showPerformanceOverlay,
    );
  }

  static double _clampScale(double value) {
    if (value.isNaN) return Tokens.textScaleDefault;
    return value < Tokens.textScaleMin
        ? Tokens.textScaleMin
        : (value > Tokens.textScaleCap ? Tokens.textScaleCap : value);
  }

  /// Reads a stored map, falling back to defaults for anything missing, the
  /// wrong type or out of range. A corrupted store degrades to defaults rather
  /// than throwing on startup.
  factory AppSettings.fromJson(Map<String, Object?> json) {
    return AppSettings(
      reduceTransparency: _boolFrom(json['reduceTransparency']) ?? false,
      reduceMotion: _boolFrom(json['reduceMotion']) ?? false,
      textScale: _clampScale(
        _numFrom(json['textScale']) ?? Tokens.textScaleDefault,
      ),
      lyricsAutoFollow: _boolFrom(json['lyricsAutoFollow']) ?? true,
      equalizer: EqualizerConfig(
        enabled: _boolFrom(json['equalizerEnabled']) ?? false,
        gains: _gainsFrom(json['equalizerGains']),
        presetName: _stringFrom(json['equalizerPreset']),
      ),
      repeatMode: _repeatFrom(json['repeatMode']),
      shuffle: _boolFrom(json['shuffle']) ?? false,
      autoplay: _boolFrom(json['autoplay']) ?? true,
      visualQuality: visualQualityFrom(json['visualQuality']),
      showPerformanceOverlay:
          _boolFrom(json['showPerformanceOverlay']) ?? false,
    );
  }

  /// Stored by name, so a hand-edited value that names no tier falls back to
  /// Auto instead of failing to start.
  static VisualQuality visualQualityFrom(Object? value) {
    for (final VisualQuality quality in VisualQuality.values) {
      if (quality.name == value) return quality;
    }
    return VisualQuality.auto;
  }

  /// Repeat mode is stored by name, so a hand-edited or older file that says
  /// something unknown falls back to Off instead of failing to start.
  static RepeatMode _repeatFrom(Object? value) {
    for (final RepeatMode mode in RepeatMode.values) {
      if (mode.name == value) return mode;
    }
    return RepeatMode.off;
  }

  /// Every reader below checks the type instead of casting: a preference that
  /// is present but the wrong type is a bad value, not a reason to crash.
  static bool? _boolFrom(Object? value) => value is bool ? value : null;

  static double? _numFrom(Object? value) =>
      value is num ? value.toDouble() : null;

  static String? _stringFrom(Object? value) =>
      value is String && value.isNotEmpty ? value : null;

  /// Reads stored gains, treating anything unparseable as "no stored shape" so
  /// a hand-edited or truncated file falls back to flat.
  ///
  /// Numbers and numeric strings both count: the store persists gains as
  /// strings so they round-trip exactly.
  static List<double>? _gainsFrom(Object? raw) {
    if (raw is! Iterable<Object?>) return null;
    final List<double> out = <double>[];
    for (final Object? value in raw) {
      if (value is num) {
        out.add(value.toDouble());
        continue;
      }
      if (value is String) {
        final double? parsed = double.tryParse(value);
        if (parsed == null) return null;
        out.add(parsed);
        continue;
      }
      return null;
    }
    return out;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'reduceTransparency': reduceTransparency,
    'reduceMotion': reduceMotion,
    'textScale': textScale,
    'lyricsAutoFollow': lyricsAutoFollow,
    'equalizerEnabled': equalizer.enabled,
    'equalizerGains': equalizer.gains,
    'equalizerPreset': equalizer.presetName,
    'repeatMode': repeatMode.name,
    'shuffle': shuffle,
    'autoplay': autoplay,
    'visualQuality': visualQuality.name,
    'showPerformanceOverlay': showPerformanceOverlay,
  };

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.reduceTransparency == reduceTransparency &&
      other.reduceMotion == reduceMotion &&
      other.textScale == textScale &&
      other.lyricsAutoFollow == lyricsAutoFollow &&
      other.equalizer == equalizer &&
      other.repeatMode == repeatMode &&
      other.shuffle == shuffle &&
      other.autoplay == autoplay &&
      other.visualQuality == visualQuality &&
      other.showPerformanceOverlay == showPerformanceOverlay;

  @override
  int get hashCode => Object.hash(
    reduceTransparency,
    reduceMotion,
    textScale,
    lyricsAutoFollow,
    equalizer,
    repeatMode,
    shuffle,
    autoplay,
    visualQuality,
    showPerformanceOverlay,
  );
}

/// Where settings are read from and written to.
///
/// The production implementation is `SharedPreferencesSettingsStore`; widget
/// tests and goldens use [InMemorySettingsStore] so no platform channel is
/// ever touched while pumping frames.
abstract class SettingsStore {
  Future<AppSettings> load();

  /// Returns null on success or a user-facing message on failure.
  Future<String?> save(AppSettings settings);
}

/// Keeps settings in memory only. The default the app and every test start on.
class InMemorySettingsStore implements SettingsStore {
  InMemorySettingsStore([AppSettings? initial])
    : _value = initial ?? const AppSettings();

  AppSettings _value;

  /// Set by tests to make saving fail, so the failure path is real.
  Object? failWith;

  @override
  Future<AppSettings> load() async => _value;

  @override
  Future<String?> save(AppSettings settings) async {
    final Object? error = failWith;
    if (error != null) throw error;
    _value = settings;
    return null;
  }
}

/// Where the app starts from. `main.dart` loads the stored settings and
/// overrides this before the first frame, so nothing waits on disk while
/// building; the default keeps tests free of persistence.
final Provider<AppSettings> initialAppSettingsProvider = Provider<AppSettings>(
  (_) => const AppSettings(),
);

/// The live settings. Every setter writes through to the [SettingsStore] and
/// reports the outcome on [settingsSaveStatusProvider], so a Settings row can
/// say "saving" and then "couldn't save" instead of silently losing the change.
class AppSettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.watch(initialAppSettingsProvider);

  SettingsStore get _store => ref.read(settingsStoreProvider);

  Future<void> _commit(AppSettings next) async {
    state = next;
    ref.read(settingsSaveStatusProvider.notifier).saving();
    try {
      final String? error = await _store.save(next);
      ref.read(settingsSaveStatusProvider.notifier).report(error);
    } catch (_) {
      // A store that throws must not take the app down; the change still holds
      // for this session and the Settings screen says it did not persist.
      ref
          .read(settingsSaveStatusProvider.notifier)
          .report(
            'Preferences could not be saved. They apply for this session.',
          );
    }
  }

  void setReduceTransparency(bool value) =>
      _commit(state.copyWith(reduceTransparency: value));

  void setReduceMotion(bool value) =>
      _commit(state.copyWith(reduceMotion: value));

  void setTextScale(double value) => _commit(state.copyWith(textScale: value));

  void setLyricsAutoFollow(bool value) =>
      _commit(state.copyWith(lyricsAutoFollow: value));

  void setEqualizer(EqualizerConfig value) =>
      _commit(state.copyWith(equalizer: value));

  void setVisualQuality(VisualQuality value) =>
      _commit(state.copyWith(visualQuality: value));

  /// Debug/profile only: the frame-stats overlay for performance runs.
  ///
  /// A release build can never commit this: neither its event loop nor its
  /// engine publishes a frame timeline, so the row does not exist on the
  /// page and this gate refuses the write outright. The gate is a compile-
  /// time constant, so the branch is dropped from release binaries rather
  /// than merely hidden behind it.
  void setShowPerformanceOverlay(bool value) {
    assert(!kReleaseMode, 'Show frame stats is debug-only.');
    if (kReleaseMode) return;
    _commit(state.copyWith(showPerformanceOverlay: value));
  }

  /// Writes the player modes the transport controls own. The controls talk to
  /// [PlaybackController], which is the single writer for these three, so this
  /// exists for the reset path and for seeding, not as a second source of truth.
  void setPlayerModes({RepeatMode? repeat, bool? shuffle, bool? autoplay}) =>
      _commit(
        state.copyWith(
          repeatMode: repeat,
          shuffle: shuffle,
          autoplay: autoplay,
        ),
      );

  /// Back to defaults, including the equalizer and the player modes. Music,
  /// queue and sign-in live elsewhere, so this touches nothing the user did not
  /// ask to reset.
  void resetAll() => _commit(const AppSettings());
}

/// How the last preference write went.
enum SettingsSaveStatus { idle, saving, failed }

class SettingsSaveStatusNotifier extends Notifier<SettingsSaveStatus> {
  @override
  SettingsSaveStatus build() => SettingsSaveStatus.idle;

  String? message;

  void saving() => state = SettingsSaveStatus.saving;

  void report(String? error) {
    message = error;
    state = error == null ? SettingsSaveStatus.idle : SettingsSaveStatus.failed;
  }
}

final NotifierProvider<SettingsSaveStatusNotifier, SettingsSaveStatus>
settingsSaveStatusProvider =
    NotifierProvider<SettingsSaveStatusNotifier, SettingsSaveStatus>(
      SettingsSaveStatusNotifier.new,
    );

/// The persistence backend. Defaults to memory; `main.dart` overrides it with
/// the shared_preferences store on platforms that have one.
final Provider<SettingsStore> settingsStoreProvider = Provider<SettingsStore>(
  (_) => InMemorySettingsStore(),
);

final NotifierProvider<AppSettingsNotifier, AppSettings> appSettingsProvider =
    NotifierProvider<AppSettingsNotifier, AppSettings>(AppSettingsNotifier.new);
