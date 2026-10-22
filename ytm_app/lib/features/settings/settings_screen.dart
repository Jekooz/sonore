import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../audio/equalizer_controller.dart';
import '../../audio/playback_controller.dart';
import '../../audio/playback_state.dart';
import '../../core/app_identity.dart';
import '../../core/app_settings.dart';
import '../../core/sidecar/sidecar_launcher.dart';
import '../../core/sidecar/sidecar_providers.dart';
import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../data/ytm_repository.dart';
import '../../routing/destinations.dart';
import '../../theme/icons.dart';
import '../../theme/tokens.dart';
import '../../ui/confirm_dialog.dart';
import '../../ui/glass_surface.dart';
import '../../ui/media_actions.dart';
import '../../ui/pill_button.dart';
import '../../ui/screen_header.dart';
import '../../ui/screen_states.dart';
import '../shell/app_shell.dart';

/// Keeps this in step with `pubspec.yaml`'s `version:`; the build does not
/// embed the package metadata, so the About row states it directly.
const String appVersion = '1.7.0-beta.1';

/// Settings, built from preferences that really change the app.
///
/// There is deliberately no output-device picker and no theme switch: the audio
/// engine exposes no device selection and v1 is dark-only, so a control for
/// either would be decorative. Diagnostics report what the local service
/// actually says — never a cookie, token or signed URL.
///
/// The Playback switches and the transport pill write the same three player
/// modes through [PlaybackController], so the two surfaces cannot disagree.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings = ref.watch(appSettingsProvider);
    final AppSettingsNotifier controller = ref.read(
      appSettingsProvider.notifier,
    );

    final double margin = Tokens.pageMargin(MediaQuery.sizeOf(context).width);

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: <Widget>[
            const _StickyHeader(),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: Tokens.contentMaxWidth,
                  ),
                  child: ListView(
                    // One content column: the same margin on both sides, and the
                    // rows below give up ListTile's own inset, so section titles,
                    // notes and buttons all start and end on the same edges.
                    padding: EdgeInsets.symmetric(
                      horizontal: margin,
                      vertical: Tokens.s8,
                    ).copyWith(bottom: Tokens.s8 + ShellClearance.of(context)),
                    children: <Widget>[
                      const _Section(title: 'Appearance'),
                      _SwitchRow(
                        title: 'Reduce transparency',
                        subtitle:
                            'Uses solid tinted surfaces instead of glass. '
                            'Also engages automatically when the system reduces '
                            'transparency or uses high contrast.',
                        value: settings.reduceTransparency,
                        onChanged: controller.setReduceTransparency,
                      ),
                      _SwitchRow(
                        title: 'Reduce motion',
                        subtitle: 'Stops shimmer and cross-fades.',
                        value: settings.reduceMotion,
                        onChanged: controller.setReduceMotion,
                      ),
                      _SliderRow(
                        title: 'Text size',
                        subtitle: 'Scales text up to the largest the layout supports.',
                        value: settings.textScale,
                        min: Tokens.textScaleMin,
                        max: Tokens.textScaleCap,
                        divisions: 6,
                        label: '${(settings.textScale * 100).round()}%',
                        onChanged: controller.setTextScale,
                      ),
                      const _Note(
                        'Theme: dark. This version ships one theme, so there is '
                        'nothing to switch.',
                      ),
                      const _Section(title: 'Playback'),
                      Consumer(
                        builder: (BuildContext context, WidgetRef inner, _) {
                          final PlaybackState playback = inner.watch(
                            playbackProvider,
                          );
                          final PlaybackController player = inner.read(
                            playbackProvider.notifier,
                          );
                          return Column(
                            children: <Widget>[
                              _SwitchRow(
                                title: 'Autoplay',
                                subtitle:
                                    'Adds recommendations when the queue '
                                    'runs out instead of stopping.',
                                value: playback.autoplay,
                                onChanged: player.setAutoplay,
                              ),
                              _SwitchRow(
                                title: 'Shuffle',
                                subtitle:
                                    'Shuffles the tracks that have not played '
                                    'yet. Turning it off restores the original order.',
                                value: playback.shuffle,
                                onChanged: player.setShuffle,
                              ),
                              _Note(
                                'Repeat (Off, All, One) cycles from the transport '
                                'controls and persists with these.',
                              ),
                              const SizedBox(height: Tokens.s8),
                              const _PlaybackEngineRow(),
                            ],
                          );
                        },
                      ),
                      const _Section(title: 'Lyrics'),
                      _SwitchRow(
                        title: 'Follow playback',
                        subtitle: 'Scrolls to the current line when lyrics have timings.',
                        value: settings.lyricsAutoFollow,
                        onChanged: controller.setLyricsAutoFollow,
                      ),
                      const _Section(title: 'Audio'),
                      Consumer(
                        builder: (BuildContext context, WidgetRef inner, _) {
                          final EqualizerState eq = inner.watch(
                            equalizerControllerProvider,
                          );
                          final String summary = !eq.config.enabled
                              ? 'Off'
                              : (eq.config.presetName ?? 'Custom');
                          return _LinkRow(
                            title: 'Equalizer',
                            subtitle: summary,
                            icon: AppIcons.faders,
                            onTap: () => context.go('/now-playing/equalizer'),
                          );
                        },
                      ),
                      const _Section(title: 'Recommendations'),
                      const _Recommendations(),
                      const _Section(title: 'Diagnostics'),
                      const _Diagnostics(),
                      const _Section(title: 'Account'),
                      const _Account(),
                      const _Section(title: 'Privacy'),
                      const _Note(
                        'Your YouTube Music session is kept by the local service '
                        'and stored encrypted on this device. The app never holds '
                        'it, and no cookie, token or signed link is shown on this '
                        'page or written to the logs.',
                      ),
                      const _Section(title: 'About'),
                      _LinkRow(
                        title: 'Version',
                        subtitle: appVersion,
                        icon: AppIcons.disc,
                        onTap: () {},
                      ),
                      const _Note(appDisclaimer),
                      const _Note(
                        'Type is Inter. Icons are Phosphor. Both are MIT '
                        'licensed; their licence files ship with the app in '
                        'assets/fonts.',
                      ),
                      const SizedBox(height: Tokens.s24),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: PillButton(
                          icon: AppIcons.arrowClockwise,
                          label: 'Reset preferences',
                          onPressed: () => _confirmReset(context, controller),
                        ),
                      ),
                      const SizedBox(height: Tokens.s32),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A destructive action needs a deliberate second step.
  Future<void> _confirmReset(
    BuildContext context,
    AppSettingsNotifier controller,
  ) async {
    final bool? confirmed = await confirmDialog(
      context,
      title: 'Reset preferences?',
      body:
          'Appearance, motion, text, lyrics, equalizer and the player '
          'modes go back to their defaults. Your music, queue and sign-in '
          'are not affected.',
      confirmLabel: 'Reset',
    );
    if (confirmed ?? false) controller.resetAll();
  }
}

/// The pinned header: a floating glass pill with the page title, the save
/// status riding under it.
///
/// It sits outside the scrolling list, so it stays put while the page scrolls,
/// and it is the same floating chrome as every other shell surface — held
/// clear of the page edges rather than docked edge to edge.
class _StickyHeader extends StatelessWidget {
  const _StickyHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Tokens.pageMarginPhone,
        Tokens.s8,
        Tokens.pageMarginPhone,
        Tokens.s8,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Tokens.contentMaxWidth),
          child: GlassSurface(
            tier: GlassTier.thin,
            shape: Tokens.shapePill,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Tokens.s4),
              child: Column(
                children: <Widget>[
                  ScreenHeader(
                    title: 'Settings',
                    onBack: () => context.go(AppDestination.home.path),
                    backLabel: 'Back to Home',
                  ),
                  const _SaveStatusBanner(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Says what the last preference write did, so "it did not stick" is never a
/// silent surprise.
class _SaveStatusBanner extends ConsumerWidget {
  const _SaveStatusBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SettingsSaveStatus status = ref.watch(settingsSaveStatusProvider);
    if (status == SettingsSaveStatus.idle) return const SizedBox.shrink();

    final String message = status == SettingsSaveStatus.saving
        ? 'Saving…'
        : (ref.read(settingsSaveStatusProvider.notifier).message ??
              'Preferences could not be saved.');

    final bool isDesktop =
        MediaQuery.sizeOf(context).width >= Tokens.breakpointDesktop;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: isDesktop
            ? Tokens.pageMarginDesktop
            : Tokens.pageMarginPhone,
      ),
      child: Row(
        children: <Widget>[
          if (status == SettingsSaveStatus.saving)
            const SizedBox(
              width: Tokens.s16,
              height: Tokens.s16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          if (status == SettingsSaveStatus.saving)
            const SizedBox(width: Tokens.s8),
          Expanded(child: Text(message, style: Tokens.caption)),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: Tokens.s24, bottom: Tokens.s8),
      child: Text(title, style: Tokens.sectionHeader),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Tokens.s8),
      child: Text(text, style: Tokens.caption, textAlign: TextAlign.left),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    // Monochrome glass styling: a filled white track with the inverted dark
    // thumb when on, and no outline — the usual system-colored default would
    // read as a second accent the glass system does not have.
    return Semantics(
      toggled: value,
      label: title,
      child: SwitchListTile(
        value: value,
        activeTrackColor: Tokens.text,
        activeThumbColor: Tokens.bg,
        inactiveThumbColor: Tokens.textMuted,
        inactiveTrackColor: Tokens.surfaceRaised,
        trackOutlineColor: const WidgetStatePropertyAll<Color>(
          Tokens.transparent,
        ),
        tileColor: Tokens.transparent,
        // Hover, pressed and focus states share one glass fill overlay.
        overlayColor: const WidgetStatePropertyAll<Color>(Tokens.glassThin),
        // No inset of its own: the row shares the list's content column, so
        // the control sits on the same right edge the notes end on.
        contentPadding: EdgeInsets.zero,
        title: Text(title, style: Tokens.rowTitle),
        subtitle: Text(subtitle, style: Tokens.caption),
        onChanged: onChanged,
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.label,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String label;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: title,
      value: label,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(title, style: Tokens.rowTitle),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(subtitle, style: Tokens.caption),
            ConstrainedBox(
              constraints: const BoxConstraints(
                // A thumb travelling the full content width on a 1920 window
                // is unusable mouse tuning; the control gets a sane maximum.
                maxWidth: Tokens.formControlMaxWidth,
              ),
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                divisions: divisions,
                label: label,
                activeColor: Tokens.text,
                inactiveColor: Tokens.surfaceRaised,
                onChanged: onChanged,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The recommendation settings: the local taste layer, the optional outside
/// services, and the button that forgets what the app has learned.
///
/// The credentials live in the local service, encrypted on this machine; the
/// app asks for them, shows them and sends them back. Nothing is written to
/// the app's own preferences, and nothing leaves the machine.
class _Recommendations extends ConsumerStatefulWidget {
  const _Recommendations();

  @override
  ConsumerState<_Recommendations> createState() => _RecommendationsState();
}

class _RecommendationsState extends ConsumerState<_Recommendations> {
  final TextEditingController _listenbrainz = TextEditingController();
  final TextEditingController _lastfm = TextEditingController();

  RecommenderSettings _settings = const RecommenderSettings();
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _listenbrainz.dispose();
    _lastfm.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final YtmRepository repository = ref.read(ytmRepositoryProvider);
    RecommenderSettings settings = const RecommenderSettings();
    try {
      settings = await repository.recommenderSettings();
    } on YtmException {
      // The service could not be reached: the defaults are shown, and the
      // rows stay usable so a retry is one tap away.
    }
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _listenbrainz.text = settings.listenbrainzToken;
      _lastfm.text = settings.lastfmApiKey;
      _loading = false;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final YtmRepository repository = ref.read(ytmRepositoryProvider);
    final RecommenderSettings next = _settings.copyWith(
      localLearning: _settings.localLearning,
      listenbrainzToken: _listenbrainz.text.trim(),
      lastfmApiKey: _lastfm.text.trim(),
    );
    try {
      await repository.saveRecommenderSettings(next);
    } on YtmException catch (error) {
      if (!mounted) return;
      showAppMessage(context, error.message);
      setState(() => _saving = false);
      return;
    }
    if (!mounted) return;
    setState(() {
      _settings = next;
      _saving = false;
    });
    showAppMessage(context, 'Recommendation settings saved');
  }

  /// A destructive action needs a deliberate second step.
  Future<void> _confirmClear() async {
    final bool? confirmed = await confirmDialog(
      context,
      title: 'Clear listening data?',
      body:
          'What this app has learned about your taste is forgotten: the '
          'plays, skips and likes it recorded, and the listening history it '
          'shows. Your YouTube Music account is not affected.',
      confirmLabel: 'Clear',
    );
    if (!(confirmed ?? false)) return;

    final YtmRepository repository = ref.read(ytmRepositoryProvider);
    try {
      await repository.clearListeningData();
    } on YtmException catch (error) {
      if (!mounted) return;
      showAppMessage(context, error.message);
      return;
    }
    if (!mounted) return;
    setState(() {
      _settings = const RecommenderSettings();
    });
    await _load();
    if (!mounted) return;
    showAppMessage(context, 'Listening data cleared');
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: Tokens.s8),
        child: Skeleton(width: 220, height: Tokens.s16),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _SwitchRow(
          title: 'Local learning',
          subtitle:
              'Learns from what you play, skip and like, and uses it to refine '
              'the recommendations.',
          value: _settings.localLearning,
          onChanged: (bool value) {
            setState(
              () => _settings = _settings.copyWith(localLearning: value),
            );
            _save();
          },
        ),
        _TokenField(
          title: 'ListenBrainz token',
          subtitle:
              'Optional. Adds the artists you listen to there as a signal.',
          controller: _listenbrainz,
          hint: 'Your ListenBrainz user token',
        ),
        _TokenField(
          title: 'Last.fm API key',
          subtitle: 'Optional. Adds similar artists and tracks.',
          controller: _lastfm,
          hint: 'Your Last.fm API key',
        ),
        const _Note(
          'Outside services are optional and are only used when they are set '
          'here. They are stored by the local service, encrypted on this '
          'machine, and are never sent anywhere else.',
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: PillButton(
            icon: AppIcons.floppyDisk,
            label: _saving ? 'Saving…' : 'Save',
            onPressed: _saving ? null : _save,
          ),
        ),
        const SizedBox(height: Tokens.s8),
        Align(
          alignment: Alignment.centerLeft,
          child: PillButton(
            icon: AppIcons.trash,
            label: 'Clear listening data',
            onPressed: _confirmClear,
          ),
        ),
        const SizedBox(height: Tokens.s8),
        _Note(
          _settings.localEventCount == 0
              ? 'Nothing has been learned yet.'
              : 'Learned from ${_settings.plays} plays, '
                    '${_settings.skips} skips and ${_settings.likes} likes.',
        ),
      ],
    );
  }
}

/// One credential field.
///
/// The value is a secret, so it is obscured until the reader asks to see it.
class _TokenField extends StatefulWidget {
  const _TokenField({
    required this.title,
    required this.subtitle,
    required this.controller,
    required this.hint,
  });

  final String title;
  final String subtitle;
  final TextEditingController controller;
  final String hint;

  @override
  State<_TokenField> createState() => _TokenFieldState();
}

class _TokenFieldState extends State<_TokenField> {
  bool _hidden = true;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Tokens.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(widget.title, style: Tokens.rowTitle),
          const SizedBox(height: Tokens.s4),
          Text(widget.subtitle, style: Tokens.caption),
          const SizedBox(height: Tokens.s8),
          TextField(
            controller: widget.controller,
            obscureText: _hidden,
            style: Tokens.subtitle,
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: Tokens.glassThin,
              hintText: widget.hint,
              hintStyle: Tokens.caption,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: _hidden ? 'Show' : 'Hide',
                icon: Icon(
                  _hidden ? AppIcons.eye : AppIcons.eyeSlash,
                  size: Tokens.iconSize,
                  color: Tokens.textSecondary,
                ),
                onPressed: () => setState(() => _hidden = !_hidden),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: title,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, size: Tokens.iconSize, color: Tokens.textSecondary),
        title: Text(title, style: Tokens.rowTitle),
        subtitle: Text(subtitle, style: Tokens.caption),
        trailing: const Icon(
          AppIcons.caretRight,
          size: Tokens.iconSize,
          color: Tokens.textMuted,
        ),
        onTap: onTap,
      ),
    );
  }
}

/// What the local service and the sidecar launcher actually report. Recovery
/// guidance comes straight from them, so a missing Python runtime is named
/// rather than shown as a generic failure.
class _Diagnostics extends ConsumerWidget {
  const _Diagnostics();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<YtmConnection> connection = ref.watch(connectionProvider);
    final AsyncValue<SidecarStatus> sidecar = ref.watch(sidecarStatusProvider);

    final YtmConnection? value = connection.value;
    final String backend = switch (connection.hasError) {
      true => 'Not reachable',
      false => switch (value?.status) {
        YtmStatus.ready => 'Ready',
        YtmStatus.signedOut => 'Running, not signed in',
        YtmStatus.offline => 'Not reachable',
        null => 'Checking…',
      },
    };

    // The launcher's failure message already names what is missing (a Python
    // runtime that cannot be resolved, a backend that exited) and is already
    // redacted, so it is safe and more useful than any wording of our own.
    final String? sidecarError = sidecar.error?.toString();
    final String runtime;
    if (sidecarError != null) {
      runtime = sidecarError.isEmpty ? 'Not running' : sidecarError;
    } else {
      runtime = sidecar.value == null ? 'Not started' : 'Running';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _KeyValueRow(label: 'Music service', value: backend),
        _KeyValueRow(label: 'Local runtime', value: runtime),
        Align(
          alignment: Alignment.centerLeft,
          child: PillButton(
            icon: AppIcons.arrowClockwise,
            label: 'Check again',
            onPressed: () {
              ref.invalidate(connectionProvider);
            },
          ),
        ),
        const SizedBox(height: Tokens.s8),
        const _Note(
          'The service runs on this computer only. If it is not reachable, '
          'restart the app and check again; use “Update playback engine” under '
          'Playback if a track will not play.',
        ),
      ],
    );
  }
}

class _KeyValueRow extends StatelessWidget {
  const _KeyValueRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Tokens.s4),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label, style: Tokens.subtitle)),
          Text(value, style: Tokens.caption),
        ],
      ),
    );
  }
}

/// Sign-in state and the account actions the service supports: the browser
/// flow the sidecar drives, and — for a machine where that cannot work — a
/// "paste request headers" fallback feeding the same hand-off endpoint.
class _Account extends ConsumerStatefulWidget {
  const _Account();

  @override
  ConsumerState<_Account> createState() => _AccountState();
}

class _AccountState extends ConsumerState<_Account> {
  /// Pasted headers live only in this controller: they go straight to the
  /// sidecar and are never stored by the app.
  final TextEditingController _headersController = TextEditingController();

  bool _showPasteField = false;
  bool _pastingIn = false;
  String? _pasteError;

  @override
  void dispose() {
    _headersController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final YtmConnection? connection = ref.watch(connectionProvider).value;

    if (connection?.status != YtmStatus.ready) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _LinkRow(
            title: 'Sign in',
            subtitle:
                'Opens Google sign-in in your browser — it finishes on '
                'its own.',
            icon: AppIcons.user,
            onTap: () => context.go(AppDestination.home.path),
          ),
          _LinkRow(
            title: _showPasteField
                ? 'Hide pasted headers'
                : 'Paste request headers',
            subtitle:
                'If the sign-in window cannot be used, paste the request '
                'headers from a signed-in music.youtube.com tab instead.',
            icon: AppIcons.linkSimple,
            onTap: () => setState(() {
              _showPasteField = !_showPasteField;
              _pasteError = null;
            }),
          ),
          if (_showPasteField) _pasteField(),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // The account's own name when the service states one, otherwise the
        // real channel handle from the same session. The service answers with
        // one of its own chrome labels ("Home") on some sessions, which the
        // sidecar now drops rather than passing on — so this never shows a
        // navigation label as if it were the account, and falls back to a
        // neutral label when there is nothing real to name.
        _KeyValueRow(
          label: 'Signed in as',
          value:
              connection?.accountName ?? connection?.handle ?? 'Your account',
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: PillButton(
            icon: AppIcons.signOut,
            label: 'Sign out',
            onPressed: () => _confirmSignOut(context, ref),
          ),
        ),
        const SizedBox(height: Tokens.s8),
      ],
    );
  }

  Widget _pasteField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TextField(
          controller: _headersController,
          maxLines: 6,
          style: Tokens.caption.copyWith(color: Tokens.text),
          decoration: InputDecoration(
            hintText:
                'cookie: SID=…; SAPISID=…\n'
                'user-agent: Mozilla/5.0 …',
            hintStyle: Tokens.caption,
            filled: true,
            fillColor: Tokens.surfaceRaised,
            border: const OutlineInputBorder(borderSide: BorderSide.none),
          ),
        ),
        if (_pasteError != null)
          Padding(
            padding: const EdgeInsets.only(top: Tokens.s4),
            child: Text(
              _pasteError!,
              style: Tokens.caption.copyWith(
                color: Tokens.text,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: Tokens.s8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: PillButton(
              icon: AppIcons.plus,
              label: _pastingIn ? 'Signing in…' : 'Use these headers',
              onPressed: _pastingIn ? null : _submitPastedHeaders,
            ),
          ),
        ),
        const SizedBox(height: Tokens.s8),
      ],
    );
  }

  /// Feeds the pasted headers to the loopback /auth/handoff endpoint: the
  /// sidecar recovers the cookie line, validates the candidate against YouTube
  /// and only then stores it — so the account shown afterwards is the validated
  /// one or nothing.
  Future<void> _submitPastedHeaders() async {
    setState(() {
      _pastingIn = true;
      _pasteError = null;
    });
    try {
      await ref
          .read(ytmRepositoryProvider)
          .signInWithPastedHeaders(_headersController.text);
      ref.invalidate(connectionProvider);
      if (mounted) {
        setState(() {
          _pastingIn = false;
          _showPasteField = false;
        });
      }
    } on YtmException catch (error) {
      if (mounted) {
        setState(() {
          _pastingIn = false;
          _pasteError = error.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _pastingIn = false;
          _pasteError = 'Sign-in did not complete. Try again.';
        });
      }
    }
  }

  Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
    final bool? confirmed = await confirmDialog(
      context,
      title: 'Sign out?',
      body:
          'The local service forgets your session. Your music stays where '
          'it is; you can sign in again at any time.',
      confirmLabel: 'Sign out',
    );
    if (!(confirmed ?? false) || !context.mounted) return;
    await ref.read(ytmRepositoryProvider).signOut();
    ref.invalidate(connectionProvider);
    if (context.mounted) context.go(AppDestination.home.path);
  }
}

/// The playback engine is the yt-dlp build the sidecar resolves stream URLs
/// with. The bundled build ages; this shows which one is in use and lets the
/// user pull the latest without waiting for an app update. The refresh runs in
/// the background on the sidecar, so after triggering it we poll the provider
/// until the result lands (or give up and say so).
class _PlaybackEngineRow extends ConsumerStatefulWidget {
  const _PlaybackEngineRow();

  @override
  ConsumerState<_PlaybackEngineRow> createState() => _PlaybackEngineRowState();
}

class _PlaybackEngineRowState extends ConsumerState<_PlaybackEngineRow> {
  bool _updating = false;
  String? _result;

  @override
  Widget build(BuildContext context) {
    final AsyncValue<PlaybackEngineInfo> engine = ref.watch(
      playbackEngineInfoProvider,
    );
    final PlaybackEngineInfo? value = engine.value;

    final String version = switch (engine) {
      AsyncData() => value?.version ?? 'Unknown',
      AsyncError() => 'Not reachable',
      _ => 'Checking…',
    };
    final String source = switch (value?.source) {
      'updated' => 'updated copy',
      'path' => 'on PATH',
      _ => 'bundled',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _KeyValueRow(label: 'Playback engine', value: '$version ($source)'),
        Align(
          alignment: Alignment.centerLeft,
          child: PillButton(
            icon: AppIcons.arrowClockwise,
            label: _updating ? 'Updating…' : 'Update playback engine',
            onPressed: _updating ? null : _update,
          ),
        ),
        if (_result != null)
          Padding(
            padding: const EdgeInsets.only(top: Tokens.s8),
            child: Text(_result!, style: Tokens.caption),
          ),
        const _Note(
          'An update is checked once a day in the background. Use this button '
          'if a track will not play, then try it again.',
        ),
      ],
    );
  }

  Future<void> _update() async {
    setState(() {
      _updating = true;
      _result = null;
    });
    try {
      await ref.read(ytmRepositoryProvider).updatePlaybackEngine();
      String? message;
      // The sidecar updates in the background; poll for the finished job so the
      // row reports the real outcome rather than "started".
      for (int attempt = 0; attempt < 24; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final PlaybackEngineInfo engine = await ref.refresh(
          playbackEngineInfoProvider.future,
        );
        if (engine.lastOk == null) continue;
        message = engine.lastOk!
            ? 'Updated to ${engine.version ?? 'the latest version'}.'
            : 'Update failed: ${_redact(engine.lastError ?? 'unknown error')}';
        break;
      }
      if (!mounted) return;
      setState(() {
        _updating = false;
        _result = message ?? 'The update is still running. Try again shortly.';
      });
    } on YtmException catch (error) {
      if (!mounted) return;
      setState(() {
        _updating = false;
        _result = _redact(error.message);
      });
    }
  }

  /// A network failure can carry a URL, which the UI never shows verbatim.
  static String _redact(String value) =>
      value.replaceAll(RegExp(r'https?://\S+'), '<url>');
}
