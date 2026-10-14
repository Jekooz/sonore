import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ytm_app/audio/equalizer.dart';
import 'package:ytm_app/audio/playback_state.dart';
import 'package:ytm_app/core/app_settings.dart';
import 'package:ytm_app/core/settings_persistence.dart';
import 'package:ytm_app/theme/tokens.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppSettings defaults', () {
    test('are the values the app boots with', () {
      const AppSettings settings = AppSettings();

      expect(settings.reduceTransparency, isFalse);
      expect(settings.reduceMotion, isFalse);
      expect(settings.textScale, Tokens.textScaleCap);
      expect(settings.lyricsAutoFollow, isTrue);
      expect(settings.equalizer, const EqualizerConfig.flat());
    });

    test('copyWith keeps unspecified fields', () {
      const AppSettings settings = AppSettings();

      final AppSettings next =
          settings.copyWith(reduceTransparency: true, textScale: 1.1);

      expect(next.reduceTransparency, isTrue);
      expect(next.textScale, 1.1);
      expect(next.reduceMotion, settings.reduceMotion);
      expect(next.lyricsAutoFollow, settings.lyricsAutoFollow);
    });
  });

  group('AppSettings validation', () {
    test('text scale is clamped to the supported range', () {
      expect(const AppSettings().copyWith(textScale: 9).textScale,
          Tokens.textScaleCap);
      expect(const AppSettings().copyWith(textScale: 0.1).textScale,
          Tokens.textScaleMin);
      expect(const AppSettings().copyWith(textScale: 1.15).textScale, 1.15);
    });

    test('an empty store produces defaults rather than an error', () {
      final AppSettings settings = AppSettings.fromJson(<String, Object?>{});

      expect(settings, const AppSettings());
    });

    test('wrong types fall back instead of throwing', () {
      final AppSettings settings = AppSettings.fromJson(<String, Object?>{
        'reduceTransparency': 'not-a-bool',
        'textScale': 'huge',
        'lyricsAutoFollow': 7,
        'equalizerGains': <Object?>['oops', 2],
      });

      expect(settings.reduceTransparency, isFalse);
      expect(settings.textScale, Tokens.textScaleCap);
      expect(settings.lyricsAutoFollow, isTrue);
    });

    test('an out-of-range stored scale is clamped on load', () {
      final AppSettings settings = AppSettings.fromJson(
        <String, Object?>{'textScale': 42.0},
      );
      expect(settings.textScale, Tokens.textScaleCap);
    });

    test('stored equalizer gains are clamped and padded', () {
      final AppSettings settings = AppSettings.fromJson(<String, Object?>{
        'equalizerEnabled': true,
        'equalizerGains': <Object?>[99, -99],
        'equalizerPreset': 'Bass boost',
      });

      expect(settings.equalizer.enabled, isTrue);
      expect(settings.equalizer.gains, hasLength(10));
      expect(settings.equalizer.gains[0], equalizerMaxGainDb);
      expect(settings.equalizer.gains[1], -equalizerMaxGainDb);
      expect(settings.equalizer.gains[9], 0);
      expect(settings.equalizer.presetName, 'Bass boost');
    });

    test('a NaN scale does not survive into the app', () {
      final AppSettings settings =
          AppSettings.fromJson(<String, Object?>{'textScale': double.nan});
      expect(settings.textScale, isNot(isNaN));
      expect(settings.textScale, Tokens.textScaleCap);
    });
  });

  group('AppSettings round trip', () {
    test('toJson then fromJson returns an equal value', () {
      final AppSettings original = AppSettings(
        reduceTransparency: true,
        reduceMotion: true,
        textScale: 1.15,
        lyricsAutoFollow: false,
        equalizer: EqualizerConfig(
          enabled: true,
          gains: <double>[9, 8, 6, 3, 0, -1, -1, 0, 1, 2],
          presetName: 'Bass boost',
        ),
      );

      final AppSettings restored =
          AppSettings.fromJson(original.toJson());

      expect(restored, original);
    });
  });

  group('InMemorySettingsStore', () {
    test('keeps what it is given', () async {
      final InMemorySettingsStore store =
          InMemorySettingsStore(const AppSettings());
      const AppSettings next = AppSettings(reduceMotion: true);

      await store.save(next);

      expect(await store.load(), next);
    });

    test('a throwing store reports rather than losing the change', () async {
      final InMemorySettingsStore store = InMemorySettingsStore()
        ..failWith = StateError('disk full');

      expect(
        store.save(const AppSettings(reduceMotion: true)),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('SharedPreferencesSettingsStore', () {
    test('preferences survive a reopen', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});

      final SettingsStore store = await SharedPreferencesSettingsStore.open();
      await store.save(AppSettings(
        reduceTransparency: true,
        textScale: 1.2,
        lyricsAutoFollow: false,
        equalizer: EqualizerConfig(
          enabled: true,
          gains: <double>[1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
          presetName: 'Vocal',
        ),
        repeatMode: RepeatMode.one,
        shuffle: true,
        autoplay: false,
      ));

      // A second open reads the same backing store, as it would across app
      // launches.
      final SettingsStore reopened = await SharedPreferencesSettingsStore.open();
      final AppSettings loaded = await reopened.load();

      expect(loaded.reduceTransparency, isTrue);
      expect(loaded.textScale, 1.2);
      expect(loaded.lyricsAutoFollow, isFalse);
      expect(loaded.equalizer.enabled, isTrue);
      expect(loaded.equalizer.gains, const <double>[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
      expect(loaded.equalizer.presetName, 'Vocal');
      // The player modes are part of the same stored record: the transport
      // settings the user left behind are the ones that come back.
      expect(loaded.repeatMode, RepeatMode.one);
      expect(loaded.shuffle, isTrue);
      expect(loaded.autoplay, isFalse);
    });

    test('an unset store loads defaults', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});

      final SettingsStore store = await SharedPreferencesSettingsStore.open();
      expect(await store.load(), const AppSettings());
    });

    test('a malformed stored value degrades to defaults', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'settings.textScale': 'not a number',
        'settings.reduceMotion': 'yes',
        'settings.equalizer.gains': <String>['x', 'y'],
        'settings.repeatMode': 'sideways',
        'settings.shuffle': 7,
      });

      final SettingsStore store = await SharedPreferencesSettingsStore.open();
      final AppSettings loaded = await store.load();

      expect(loaded.textScale, Tokens.textScaleCap);
      expect(loaded.reduceMotion, isFalse);
      expect(loaded.equalizer.gains, const EqualizerConfig.flat().gains);
      expect(loaded.repeatMode, RepeatMode.off);
      expect(loaded.shuffle, isFalse);
      // Autoplay was never written, so the default stands: an unset mode is not
      // the same thing as a corrupt one.
      expect(loaded.autoplay, isTrue);
    });

    test('clearing the preset removes the stored name', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});

      final SettingsStore store = await SharedPreferencesSettingsStore.open();
      await store.save(AppSettings(
        equalizer: EqualizerConfig(enabled: true, presetName: 'Vocal'),
      ));
      await store.save(const AppSettings());

      final AppSettings loaded = await store.load();
      expect(loaded.equalizer.presetName, isNull);
    });
  });

  group('AppSettingsNotifier', () {
    test('starts from the initial provider value', () {
      final ProviderContainer container = ProviderContainer(
        overrides: [
          initialAppSettingsProvider
              .overrideWithValue(const AppSettings(reduceMotion: true)),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(appSettingsProvider).reduceMotion, isTrue);
    });

    test('a setter writes through to the store and reports success',
        () async {
      final InMemorySettingsStore store = InMemorySettingsStore();
      final ProviderContainer container = ProviderContainer(
        overrides: [settingsStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);

      container
          .read(appSettingsProvider.notifier)
          .setReduceTransparency(true);
      await pumpEventQueue();

      expect((await store.load()).reduceTransparency, isTrue);
      expect(
        container.read(settingsSaveStatusProvider),
        SettingsSaveStatus.idle,
      );
    });

    test('a failing store surfaces a status instead of throwing', () async {
      final InMemorySettingsStore store = InMemorySettingsStore()
        ..failWith = StateError('no disk');
      final ProviderContainer container = ProviderContainer(
        overrides: [settingsStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);

      container.read(appSettingsProvider.notifier).setReduceMotion(true);
      await pumpEventQueue();

      // The change still applies for this session.
      expect(container.read(appSettingsProvider).reduceMotion, isTrue);
      expect(
        container.read(settingsSaveStatusProvider),
        SettingsSaveStatus.failed,
      );
      expect(
        container.read(settingsSaveStatusProvider.notifier).message,
        isNotEmpty,
      );
    });

    test('reset preferences returns every field to its default', () async {
      final InMemorySettingsStore store = InMemorySettingsStore();
      final ProviderContainer container = ProviderContainer(
        overrides: [settingsStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);

      final AppSettingsNotifier notifier =
          container.read(appSettingsProvider.notifier);
      notifier.setReduceTransparency(true);
      await pumpEventQueue();
      notifier.setTextScale(1.1);
      await pumpEventQueue();
      notifier.resetAll();
      await pumpEventQueue();

      expect(container.read(appSettingsProvider), const AppSettings());
      expect(await store.load(), const AppSettings());
    });
  });
}
