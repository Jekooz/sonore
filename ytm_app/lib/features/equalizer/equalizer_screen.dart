import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../audio/equalizer.dart';
import '../../audio/equalizer_controller.dart';
import '../../routing/destinations.dart';
import '../../theme/icons.dart';
import '../../theme/tokens.dart';
import '../../ui/glass_surface.dart';
import '../../ui/pill_button.dart';
import '../../ui/screen_header.dart';
import '../../ui/screen_states.dart';
import '../shell/app_shell.dart';

/// Ten-band equalizer.
///
/// Every control here writes into the running engine and the engine's own
/// answer is shown back, so nothing on this screen is decorative. When the
/// engine cannot shape audio, the screen says exactly that instead of showing
/// sliders that do nothing — which design.md section H requires.
class EqualizerScreen extends ConsumerWidget {
  const EqualizerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool supported = ref.watch(equalizerSupportedProvider);

    return Scaffold(
      backgroundColor: Tokens.transparent,
      body: SafeArea(
        child: Column(
          children: <Widget>[
            ScreenHeader(
              title: 'Equalizer',
              onBack: () => context.go(AppDestination.nowPlaying.path),
            ),
            Expanded(
              child: supported
                  ? const _EqualizerControls()
                  : const _NoEngineSupport(),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the engine would need for this screen to be real.
class _NoEngineSupport extends StatelessWidget {
  const _NoEngineSupport();

  @override
  Widget build(BuildContext context) {
    return const StateMessage(
      message: 'This player cannot apply an equalizer yet.',
      footnote: 'Ten-band EQ needs the audio engine to expose a filter chain. '
          'Nothing here is shown as adjustable, because nothing here would '
          'change what you hear.',
    );
  }
}

class _EqualizerControls extends ConsumerWidget {
  const _EqualizerControls();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final EqualizerState state = ref.watch(equalizerControllerProvider);
    final EqualizerController controller =
        ref.read(equalizerControllerProvider.notifier);

    // The selected preset is stated where the reader set it: right next to
    // the switch the page is named by, and again on the preset chip itself.
    final String summary = !state.config.enabled
        ? 'Off'
        : (state.config.presetName ?? 'Custom');

    return SingleChildScrollView(
      padding: EdgeInsets.only(
        bottom: Tokens.s16 + ShellClearance.of(context),
      ),
      // A form, not a dashboard: one centred column that never stretches
      // across a wide window.
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Tokens.formMaxWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              GlassSurface(
                radius: Tokens.rLarge,
                child: Padding(
                  padding: const EdgeInsets.all(Tokens.s16),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            const Text('Equalizer', style: Tokens.rowTitle),
                            const SizedBox(height: Tokens.s4),
                            Text(summary, style: Tokens.caption),
                          ],
                        ),
                      ),
                      Semantics(
                        toggled: state.config.enabled,
                        label: 'Equalizer',
                        child: Switch(
                          value: state.config.enabled,
                          activeThumbColor: Tokens.text,
                          onChanged: state.isApplying
                              ? null
                              : (bool value) => controller.setEnabled(value),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: Tokens.s16),
              GlassSurface(
                radius: Tokens.rLarge,
                child: Padding(
                  padding: const EdgeInsets.all(Tokens.s16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      const Text('Preset', style: Tokens.sectionHeader),
                      const SizedBox(height: Tokens.s8),
                      // A wrapped chip row: chips keep their own width, a
                      // second run starts at the same left edge as the first,
                      // and the selected one is stated both visually and to
                      // assistive technology.
                      Wrap(
                        alignment: WrapAlignment.start,
                        crossAxisAlignment: WrapCrossAlignment.start,
                        spacing: Tokens.s8,
                        runSpacing: Tokens.s8,
                        children: <Widget>[
                          for (final EqualizerPreset preset in equalizerPresets)
                            _PresetChip(
                              label: preset.name,
                              selected: state.config.presetName == preset.name,
                              onPressed: state.isApplying
                                  ? null
                                  : () => controller.setPreset(preset),
                            ),
                        ],
                      ),
                      const SizedBox(height: Tokens.s24),
                      const Text('Bands', style: Tokens.sectionHeader),
                      const SizedBox(height: Tokens.s4),
                      // The range every band moves over, stated once: the
                      // readouts below are dB values, and this is the scale
                      // they are read against.
                      Text(
                        '±${equalizerMaxGainDb.round()} dB per band',
                        style: Tokens.subtitle,
                      ),
                      const SizedBox(height: Tokens.s8),
                      SizedBox(
                        height: Tokens.eqBandsHeight,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            for (int i = 0;
                                i < equalizerBandFrequenciesHz.length;
                                i++)
                              Expanded(
                                child: _BandControl(
                                  frequencyHz: equalizerBandFrequenciesHz[i],
                                  gainDb: state.config.gains[i],
                                  enabled:
                                      state.config.enabled && !state.isApplying,
                                  onChanged: (double value) =>
                                      controller.setGain(i, value),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: Tokens.s16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  PillButton(
                    icon: AppIcons.arrowClockwise,
                    label: 'Reset to flat',
                    onPressed: state.isApplying
                        ? null
                        : () => controller.reset(),
                  ),
                ],
              ),
              if (state.isApplying) ...<Widget>[
                const SizedBox(height: Tokens.s16),
                const LinearProgressIndicator(minHeight: 2),
              ],
              if (state.error != null) ...<Widget>[
                const SizedBox(height: Tokens.s16),
                StateMessage(message: state.error!),
              ],
              // The engine's own answer, so the reader (and the tests) can see
              // the configuration really landed rather than assuming it did.
              if (state.appliedFilter != null &&
                  state.appliedFilter!.isNotEmpty) ...<Widget>[
                const SizedBox(height: Tokens.s16),
                Text('Engine reports', style: Tokens.sectionHeader),
                const SizedBox(height: Tokens.s4),
                Text(
                  state.appliedFilter!,
                  style: Tokens.caption,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: Tokens.s32),
            ],
          ),
        ),
      ),
    );
  }
}

/// One preset chip.
///
/// The selected flag is exposed to assistive technology as well as painted, so
/// which preset is in use is never a color-only signal.
class _PresetChip extends StatelessWidget {
  const _PresetChip({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      child: PillButton(
        label: label,
        isActive: selected,
        onPressed: onPressed,
      ),
    );
  }
}

/// One frequency band: a vertical slider with a readable label and a gain
/// readout, so it works with a mouse, a keyboard and a screen reader.
class _BandControl extends StatelessWidget {
  const _BandControl({
    required this.frequencyHz,
    required this.gainDb,
    required this.enabled,
    required this.onChanged,
  });

  final int frequencyHz;
  final double gainDb;
  final bool enabled;
  final ValueChanged<double> onChanged;

  String get _frequencyLabel => frequencyHz >= 1000
      ? '${frequencyHz ~/ 1000}k'
      : '$frequencyHz';

  /// This band's gain with its sign and its unit. A bare number leaves the
  /// reader to guess the unit and whether it is a boost or a cut.
  String get _gainLabel {
    final int db = gainDb.round();
    return '${db > 0 ? '+' : ''}$db dB';
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '$_frequencyLabel hertz band',
      value: _gainLabel,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Text(
            _gainLabel,
            style: Tokens.subtitle,
            textAlign: TextAlign.center,
          ),
          Expanded(
            child: RotatedBox(
              quarterTurns: -1,
              child: SliderTheme(
                data: Tokens.sliderGlass,
                child: Slider(
                  value: gainDb,
                  min: -equalizerMaxGainDb,
                  max: equalizerMaxGainDb,
                  divisions: 24,
                  label: '${gainDb.round()} dB',
                  onChanged: enabled ? onChanged : null,
                ),
              ),
            ),
          ),
          Text(
            _frequencyLabel,
            style: Tokens.subtitle,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
