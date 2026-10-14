import 'package:shared_preferences/shared_preferences.dart';

import 'app_settings.dart';

/// Persists [AppSettings] with `shared_preferences`.
///
/// Every read validates rather than trusts: a preference that is missing, the
/// wrong type or out of range falls back to its default, and a store that
/// throws while loading leaves the app on defaults instead of failing to start.
class SharedPreferencesSettingsStore implements SettingsStore {
  SharedPreferencesSettingsStore._(this._prefs);

  final SharedPreferences _prefs;

  static const String _kReduceTransparency = 'settings.reduceTransparency';
  static const String _kReduceMotion = 'settings.reduceMotion';
  static const String _kTextScale = 'settings.textScale';
  static const String _kLyricsAutoFollow = 'settings.lyricsAutoFollow';
  static const String _kEqualizerEnabled = 'settings.equalizer.enabled';
  static const String _kEqualizerGains = 'settings.equalizer.gains';
  static const String _kEqualizerPreset = 'settings.equalizer.preset';
  static const String _kRepeatMode = 'settings.repeatMode';
  static const String _kShuffle = 'settings.shuffle';
  static const String _kAutoplay = 'settings.autoplay';

  /// Opens the platform store. Throws only if the platform has no store at all,
  /// which the composition root turns into in-memory settings.
  static Future<SettingsStore> open() async =>
      SharedPreferencesSettingsStore._(await SharedPreferences.getInstance());

  @override
  Future<AppSettings> load() async {
    // Read raw values rather than the typed getters: those throw on a value
    // that is present but the wrong type, and a preference the user never set
    // or that a stray write corrupted must degrade to its default, not stop
    // the app from starting.
    final Map<String, Object?> json = <String, Object?>{
      'reduceTransparency': _prefs.get(_kReduceTransparency),
      'reduceMotion': _prefs.get(_kReduceMotion),
      'textScale': _prefs.get(_kTextScale),
      'lyricsAutoFollow': _prefs.get(_kLyricsAutoFollow),
      'equalizerEnabled': _prefs.get(_kEqualizerEnabled),
      'equalizerGains': _prefs.get(_kEqualizerGains),
      'equalizerPreset': _prefs.get(_kEqualizerPreset),
      'repeatMode': _prefs.get(_kRepeatMode),
      'shuffle': _prefs.get(_kShuffle),
      'autoplay': _prefs.get(_kAutoplay),
    };
    return AppSettings.fromJson(json);
  }

  @override
  Future<String?> save(AppSettings settings) async {
    final Map<String, Object?> json = settings.toJson();
    try {
      await _prefs.setBool(
        _kReduceTransparency,
        json['reduceTransparency']! as bool,
      );
      await _prefs.setBool(_kReduceMotion, json['reduceMotion']! as bool);
      await _prefs.setDouble(_kTextScale, json['textScale']! as double);
      await _prefs.setBool(
        _kLyricsAutoFollow,
        json['lyricsAutoFollow']! as bool,
      );
      await _prefs.setBool(
        _kEqualizerEnabled,
        json['equalizerEnabled']! as bool,
      );
      final List<double> gains =
          (json['equalizerGains']! as List<Object?>).cast<double>();
      await _prefs.setStringList(
        _kEqualizerGains,
        gains.map((double g) => g.toString()).toList(),
      );
      final String? preset = json['equalizerPreset'] as String?;
      if (preset == null) {
        await _prefs.remove(_kEqualizerPreset);
      } else {
        await _prefs.setString(_kEqualizerPreset, preset);
      }
      await _prefs.setString(_kRepeatMode, json['repeatMode']! as String);
      await _prefs.setBool(_kShuffle, json['shuffle']! as bool);
      await _prefs.setBool(_kAutoplay, json['autoplay']! as bool);
      return null;
    } catch (_) {
      return 'Preferences could not be saved. They apply for this session.';
    }
  }
}
