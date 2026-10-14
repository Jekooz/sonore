import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/generated/libmpv/bindings.dart';

/// Real equalizer support for the playback engine.
///
/// media_kit's Dart `Player` API exposes volume, rate, pitch and audio devices
/// but no audio filters, so ten-band EQ is reached the same way media_kit's own
/// native player talks to libmpv: through the generated bindings and the player
/// handle. The filter is mpv's `af` property, an ffmpeg `equalizer` chain — one
/// band per stage — which is real DSP on the audio being played, not a
/// decorative slider.
///
/// Every value this writes is read straight back off the engine in
/// [LibmpvEqualizer.readFilter], so "the control changed the processing
/// configuration" is a fact the tests assert rather than a claim.

/// The ten bands of the graphic equalizer, in Hz.
const List<int> equalizerBandFrequenciesHz = <int>[
  31,
  62,
  125,
  250,
  500,
  1000,
  2000,
  4000,
  8000,
  16000,
];

/// The widest boost or cut a single band may request, in dB.
const double equalizerMaxGainDb = 12.0;

/// The engine's equalizer state: on/off plus one gain per band.
///
/// Gains are clamped into `[-12, +12]` dB and always length
/// [equalizerBandFrequenciesHz].length, so a configuration handed to the engine
/// is always one it can accept.
@immutable
class EqualizerConfig {
  EqualizerConfig({
    required this.enabled,
    List<double>? gains,
    this.presetName,
  }) : gains = _normalise(gains);

  /// Off, all bands flat. The state the app boots in.
  const EqualizerConfig.flat()
      : enabled = false,
        gains = _flat,
        presetName = null;

  final bool enabled;

  /// dB per band, index-aligned with [equalizerBandFrequenciesHz].
  final List<double> gains;

  /// Name of the preset these gains came from, or null for a manual shape.
  final String? presetName;

  bool get isFlat => gains.every((double g) => g == 0);

  /// A copy with [bandIndex] set to [gainDb], clamped to the legal range.
  EqualizerConfig withGain(int bandIndex, double gainDb) {
    if (bandIndex < 0 || bandIndex >= gains.length) return this;
    final List<double> next = List<double>.from(gains);
    next[bandIndex] = clampDouble(gainDb, -equalizerMaxGainDb, equalizerMaxGainDb);
    return EqualizerConfig(
      enabled: enabled,
      gains: next,
      // Editing a band by hand means the shape is no longer a named preset.
      presetName: null,
    );
  }

  EqualizerConfig withEnabled(bool value) => EqualizerConfig(
        enabled: value,
        gains: gains,
        presetName: presetName,
      );

  static const List<double> _flat = <double>[
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  ];

  static List<double> _normalise(List<double>? gains) {
    if (gains == null || gains.isEmpty) return _flat;
    final List<double> out = <double>[];
    for (int i = 0; i < equalizerBandFrequenciesHz.length; i++) {
      final double raw = i < gains.length ? gains[i] : 0;
      out.add(clampDouble(raw, -equalizerMaxGainDb, equalizerMaxGainDb));
    }
    return out;
  }

  @override
  bool operator ==(Object other) =>
      other is EqualizerConfig &&
      other.enabled == enabled &&
      other.presetName == presetName &&
      listEquals(other.gains, gains);

  @override
  int get hashCode => Object.hash(enabled, presetName, Object.hashAll(gains));
}

/// A named starting shape. Only real, applied presets — nothing here is
/// decorative, because selecting one is written to the engine.
@immutable
class EqualizerPreset {
  const EqualizerPreset(this.name, this.gains);

  final String name;
  final List<double> gains;

  EqualizerConfig toConfig() =>
      EqualizerConfig(enabled: true, gains: gains, presetName: name);
}

const List<EqualizerPreset> equalizerPresets = <EqualizerPreset>[
  EqualizerPreset('Flat', <double>[0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
  EqualizerPreset('Bass boost', <double>[9, 8, 6, 3, 0, -1, -1, 0, 1, 2]),
  EqualizerPreset('Treble boost', <double>[1, 1, 1, 2, 3, 4, 6, 8, 9, 10]),
  EqualizerPreset('Vocal', <double>[-3, -2, 0, 3, 6, 6, 4, 2, 0, -1]),
  EqualizerPreset(
    'Electronic',
    <double>[7, 6, 2, 0, -2, 2, 1, 3, 6, 7],
  ),
];

/// The mpv `af` value that applies [gains] to the audio pipeline.
///
/// One ffmpeg `equalizer` stage per band, chained inside a single `lavfi`
/// graph. Pure so it is unit-testable without a native library.
String buildMpvAudioFilter(List<double> gains) {
  final StringBuffer graph = StringBuffer();
  for (int i = 0; i < gains.length; i++) {
    if (i > 0) graph.write(',');
    graph.write(
      'equalizer=f=${equalizerBandFrequenciesHz[i]}'
      ':t=q:w=1.41:g=${gains[i].toStringAsFixed(2)}',
    );
  }
  return 'lavfi=[$graph]';
}

/// Raised when the engine rejected an equalizer configuration. The message is
/// taken from libmpv's own error text, which never carries a stream URL.
class EqualizerException implements Exception {
  const EqualizerException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The engine's real audio-shaping capability.
///
/// A null instance means "this engine cannot shape audio", and the Equalizer
/// screen renders its honest unavailable state rather than controls that do
/// nothing.
abstract class EqualizerEngine {
  /// Whether this engine can shape audio at all.
  bool get isSupported;

  /// Writes [config] into the live audio pipeline.
  Future<void> apply(EqualizerConfig config);

  /// The filter the engine reports it is currently holding, exactly as it
  /// states it — the evidence that a control change really landed. Null when
  /// the engine cannot be asked.
  Future<String?> readFilter();
}

/// An [EqualizerEngine] that is incapable of shaping audio, used where the
/// platform or the test double has no real pipeline to write to.
class UnavailableEqualizer implements EqualizerEngine {
  const UnavailableEqualizer({this.reason});

  final String? reason;

  @override
  bool get isSupported => false;

  @override
  Future<void> apply(EqualizerConfig config) async {
    throw EqualizerException(
      reason ?? 'This engine cannot apply an equalizer.',
    );
  }

  @override
  Future<String?> readFilter() async => null;
}

/// [EqualizerEngine] backed by the running libmpv instance.
///
/// [handle] resolves to `media_kit`'s `Player.handle`, the `mpv_handle*` its
/// own native player uses. Nothing here loads a second audio engine or a new
/// library: it opens the libmpv that media_kit already shipped and links.
class LibmpvEqualizer implements EqualizerEngine {
  LibmpvEqualizer(this._handle);

  /// Resolved on use rather than captured, because the player has no native
  /// handle until it is constructed.
  final Future<int> Function() _handle;

  MPV? _mpv;

  /// Opens the same libmpv media_kit plays through.
  ///
  /// media_kit keeps its resolved path private, so this resolves the shared
  /// library the same way it does rather than reaching into another package's
  /// `lib/src` — which would break silently on a media_kit upgrade.
  MPV _bindings() {
    final MPV? existing = _mpv;
    if (existing != null) return existing;
    final Map<String, List<String>> names = <String, List<String>>{
      'windows': <String>['libmpv-2.dll', 'mpv-2.dll', 'mpv-1.dll'],
      'linux': <String>['libmpv.so', 'libmpv.so.2', 'libmpv.so.1'],
      'macos': <String>['Mpv.framework/Mpv', 'libmpv.dylib'],
      'android': <String>['libmpv.so'],
    };
    final List<String>? candidates = names[Platform.operatingSystem];
    if (candidates == null) {
      throw const EqualizerException(
        'This platform has no libmpv for the equalizer to use.',
      );
    }
    for (final String name in candidates) {
      try {
        final MPV mpv = MPV(DynamicLibrary.open(name));
        _mpv = mpv;
        return mpv;
      } catch (_) {
        // Try the next name, exactly as media_kit does.
      }
    }
    throw const EqualizerException('libmpv is not available on this system.');
  }

  @override
  bool get isSupported {
    try {
      _bindings();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> apply(EqualizerConfig config) async {
    final int address = await _handle();
    if (address == 0) {
      throw const EqualizerException('The audio engine is not ready yet.');
    }
    final MPV mpv = _bindings();
    final Pointer<mpv_handle> ctx = Pointer<mpv_handle>.fromAddress(address);
    final String value = config.enabled ? buildMpvAudioFilter(config.gains) : '';

    final Pointer<Uint8> name = 'af'.toNativeUtf8().cast<Uint8>();
    final Pointer<Uint8> data = value.toNativeUtf8().cast<Uint8>();
    int code;
    try {
      code = mpv.mpv_set_property_string(ctx, name.cast(), data.cast());
    } finally {
      malloc.free(name);
      malloc.free(data);
    }
    if (code < 0) {
      throw EqualizerException(
        'The audio engine rejected the equalizer: '
        '${mpv.mpv_error_string(code).cast<Utf8>().toDartString()}',
      );
    }
  }

  @override
  Future<String?> readFilter() async {
    try {
      final int address = await _handle();
      if (address == 0) return null;
      final MPV mpv = _bindings();
      final Pointer<mpv_handle> ctx = Pointer<mpv_handle>.fromAddress(address);
      final Pointer<Uint8> name = 'af'.toNativeUtf8().cast<Uint8>();
      Pointer<Int8> result;
      try {
        result = mpv.mpv_get_property_string(ctx, name.cast());
      } finally {
        malloc.free(name);
      }
      if (result == nullptr) return null;
      final String value = result.cast<Utf8>().toDartString();
      mpv.mpv_free(result.cast());
      return value;
    } catch (_) {
      // No engine to ask (a widget test, a platform without libmpv): the
      // caller treats null as "cannot be verified", never as "applied".
      return null;
    }
  }
}
