import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ytm_app/audio/equalizer.dart';
import 'package:ytm_app/audio/equalizer_controller.dart';
import 'package:ytm_app/audio/playback_service.dart';
import 'package:ytm_app/core/app_settings.dart';

import 'support/fake_engine.dart';

void main() {
  group('EqualizerConfig', () {
    test('flat is off, unbanded and unnamed', () {
      const EqualizerConfig config = EqualizerConfig.flat();

      expect(config.enabled, isFalse);
      expect(config.isFlat, isTrue);
      expect(config.presetName, isNull);
      expect(config.gains, hasLength(equalizerBandFrequenciesHz.length));
    });

    test('gains are clamped into the legal range', () {
      final EqualizerConfig config = EqualizerConfig(
        enabled: true,
        gains: List<double>.filled(equalizerBandFrequenciesHz.length, 99),
      );

      expect(config.gains.every((double g) => g == equalizerMaxGainDb), isTrue);

      final EqualizerConfig quiet = EqualizerConfig(
        enabled: true,
        gains: List<double>.filled(equalizerBandFrequenciesHz.length, -99),
      );
      expect(quiet.gains.every((double g) => g == -equalizerMaxGainDb), isTrue);
    });

    test('a short gain list is padded rather than rejected', () {
      final EqualizerConfig config =
          EqualizerConfig(enabled: true, gains: const <double>[3, 2]);

      expect(config.gains, hasLength(equalizerBandFrequenciesHz.length));
      expect(config.gains[0], 3);
      expect(config.gains[1], 2);
      expect(config.gains[2], 0);
    });

    test('editing a band clamps it and clears the preset name', () {
      const EqualizerConfig start = EqualizerConfig.flat();
      final EqualizerConfig withPreset = EqualizerConfig(
        enabled: true,
        gains: const <double>[1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
        presetName: 'Bass boost',
      );

      final EqualizerConfig edited = withPreset.withGain(0, 40);
      expect(edited.gains[0], equalizerMaxGainDb);
      expect(edited.presetName, isNull,
          reason: 'a hand-edited shape is no longer a named preset');

      // An out-of-range index is ignored rather than corrupting the config.
      expect(start.withGain(99, 5).gains, start.gains);
    });

    test('every shipped preset is a legal configuration', () {
      for (final EqualizerPreset preset in equalizerPresets) {
        final EqualizerConfig config = preset.toConfig();
        expect(config.enabled, isTrue, reason: preset.name);
        expect(config.presetName, preset.name);
        expect(config.gains, hasLength(equalizerBandFrequenciesHz.length));
        expect(
          config.gains.every(
            (double g) => g >= -equalizerMaxGainDb && g <= equalizerMaxGainDb,
          ),
          isTrue,
          reason: preset.name,
        );
      }
    });
  });

  group('buildMpvAudioFilter', () {
    test('is one lavfi graph with a real filter per band', () {
      final String filter = buildMpvAudioFilter(
        EqualizerConfig(
          enabled: true,
          gains: List<double>.filled(equalizerBandFrequenciesHz.length, 0),
        ).gains,
      );

      expect(filter, startsWith('lavfi=['));
      expect(filter, endsWith(']'));
      // Ten stages, one per band.
      expect(RegExp('equalizer=').allMatches(filter), hasLength(10));
      // The real ffmpeg filter parameters, not a placeholder.
      expect(filter, contains('equalizer=f=31:t=q:w=1.41:g=0.00'));
      expect(filter, contains('equalizer=f=16000:t=q:w=1.41:g=0.00'));
    });

    test('a band gain appears in the engine string', () {
      final EqualizerConfig config = const EqualizerConfig.flat()
          .withGain(2, 6.5)
          .withEnabled(true);

      final String filter = buildMpvAudioFilter(config.gains);
      expect(filter, contains('f=125:t=q:w=1.41:g=6.50'));
    });
  });

  group('EqualizerController', () {
    ProviderContainer container(FakePlaybackEngine engine) {
      final ProviderContainer container = ProviderContainer(
        overrides: [
          playbackEngineProvider.overrideWithValue(engine),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('a band change is written to the engine and read back', () async {
      final FakePlaybackEngine engine = FakePlaybackEngine();
      final ProviderContainer c = container(engine);
      final EqualizerController controller =
          c.read(equalizerControllerProvider.notifier);

      // Shaping bands while off must not silently turn the EQ on, so this
      // turns it on first, exactly as the screen does.
      controller.setEnabled(true);
      await pumpEventQueue();
      controller.setGain(0, 6);
      await pumpEventQueue();

      final EqualizerState state = c.read(equalizerControllerProvider);
      expect(state.config.gains[0], 6);
      expect(state.config.enabled, isTrue);
      expect(state.isApplying, isFalse);
      expect(state.error, isNull);
      expect(engine.equalizerEngine.applied.last.gains[0], 6);
      // The engine's own answer, so the change demonstrably landed.
      expect(state.appliedFilter, contains('f=31:t=q:w=1.41:g=6.00'));
    });

    test('editing bands while off leaves the engine untouched', () async {
      final FakePlaybackEngine engine = FakePlaybackEngine();
      final ProviderContainer c = container(engine);

      c.read(equalizerControllerProvider.notifier).setGain(0, 6);
      await pumpEventQueue();

      final EqualizerState state = c.read(equalizerControllerProvider);
      expect(state.config.enabled, isFalse,
          reason: 'a gain change must not silently switch the EQ on');
      // Off means no filter chain on the audio, whatever the bands hold.
      expect(state.appliedFilter, isEmpty);
      expect(engine.equalizerEngine.applied.last.enabled, isFalse);
    });

    test('turning it off writes an empty filter chain', () async {
      final FakePlaybackEngine engine = FakePlaybackEngine();
      final ProviderContainer c = container(engine);

      c.read(equalizerControllerProvider.notifier).setEnabled(true);
      await pumpEventQueue();
      c.read(equalizerControllerProvider.notifier).setEnabled(false);
      await pumpEventQueue();

      final EqualizerState state = c.read(equalizerControllerProvider);
      expect(state.config.enabled, isFalse);
      expect(state.appliedFilter, isEmpty);
      expect(engine.equalizerEngine.applied.last.enabled, isFalse);
    });

    test('a preset reaches the engine with its name kept', () async {
      final FakePlaybackEngine engine = FakePlaybackEngine();
      final ProviderContainer c = container(engine);

      final EqualizerPreset preset = equalizerPresets
          .firstWhere((EqualizerPreset p) => p.name == 'Bass boost');
      c.read(equalizerControllerProvider.notifier).setPreset(preset);
      await pumpEventQueue();

      final EqualizerState state = c.read(equalizerControllerProvider);
      expect(state.config.presetName, 'Bass boost');
      expect(state.config.gains, preset.gains);
      expect(state.appliedFilter, contains('f=31:t=q:w=1.41:g=9.00'));
    });

    test('reset returns to flat and off', () async {
      final FakePlaybackEngine engine = FakePlaybackEngine();
      final ProviderContainer c = container(engine);
      final EqualizerController controller =
          c.read(equalizerControllerProvider.notifier);

      controller.setEnabled(true);
      await pumpEventQueue();
      controller.setGain(5, -9);
      await pumpEventQueue();
      controller.reset();
      await pumpEventQueue();

      final EqualizerState state = c.read(equalizerControllerProvider);
      expect(state.config.enabled, isFalse);
      expect(state.config.isFlat, isTrue);
      expect(state.appliedFilter, isEmpty);
    });

    test('an engine that refuses reports the failure, not a crash', () async {
      final FakePlaybackEngine engine = FakePlaybackEngine();
      engine.equalizerEngine.applyError =
          const EqualizerException('bad filter');
      final ProviderContainer c = container(engine);

      c.read(equalizerControllerProvider.notifier).setEnabled(true);
      await pumpEventQueue();

      final EqualizerState state = c.read(equalizerControllerProvider);
      expect(state.error, 'bad filter');
      expect(state.isApplying, isFalse);
      expect(engine.equalizerEngine.applied, isEmpty);
    });

    test('an engine without shaping support says so instead of pretending',
        () async {
      final FakePlaybackEngine engine = FakePlaybackEngine();
      engine.equalizerEngine.supported = false;
      final ProviderContainer c = container(engine);

      final EqualizerController controller =
          c.read(equalizerControllerProvider.notifier);
      expect(controller.isSupported, isFalse);

      controller.setEnabled(true);
      await pumpEventQueue();

      final EqualizerState state = c.read(equalizerControllerProvider);
      expect(state.error, contains('cannot apply an equalizer'));
      expect(engine.equalizerEngine.applied, isEmpty,
          reason: 'nothing must be written to an engine that cannot shape audio');
    });

    test('the configuration is persisted with every change', () async {
      final FakePlaybackEngine engine = FakePlaybackEngine();
      final ProviderContainer c = container(engine);

      c.read(equalizerControllerProvider.notifier).setGain(3, 4);
      await pumpEventQueue();

      final AppSettings settings = c.read(appSettingsProvider);
      expect(settings.equalizer.gains[3], 4);
      expect(settings.equalizer.enabled, isFalse);
    });
  });

  group('UnavailableEqualizer', () {
    test('reports itself as incapable and refuses to apply', () async {
      const EqualizerEngine engine = UnavailableEqualizer();
      expect(engine.isSupported, isFalse);
      expect(engine.readFilter(), completion(isNull));
      expect(engine.apply(const EqualizerConfig.flat()),
          throwsA(isA<EqualizerException>()));
    });
  });
}
