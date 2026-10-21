import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../audio/playback_controller.dart';
import '../../audio/playback_service.dart';
import '../../audio/playback_state.dart';
import '../../routing/app_router.dart';
import '../../routing/destinations.dart';
import '../../theme/tokens.dart';
import '../../ui/ambient/ambient_backdrop.dart';
import '../search/search_controller.dart';
import 'nav_bottom_bar.dart';
import 'nav_tab_bar.dart';
import 'now_playing_bar.dart';

/// The adaptive shell: navigation, the responsive content area and the
/// persistent Now Playing bar all live here, so no page owns the player.
///
/// Layout rules:
/// - the navigation menu is floating chrome. Under [Tokens.breakpointPhone]
///   it is the compact glass bottom pill; at [Tokens.breakpointPhone] and
///   wider it is the floating glass top tab bar;
/// - the Now Playing bar hovers too. It is the same thick-glass pill as the
///   navigation, positioned in the same Stack layer order (content, then
///   chrome), so it never displaces layout — pages simply receive a computed
///   bottom inset to clear it.
///
/// The top tab bar floats over a reserved strip ([Tokens.shellTopInset]) rather
/// than taking a layout column, so it reads as chrome rather than a panel.
/// Navigation is deliberately identical either side of the breakpoint: the
/// same four destinations, the same route-following highlight, the same
/// Settings action.
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.navigationShell, this.titleBar});

  final StatefulNavigationShell navigationShell;

  /// The Windows title bar, when the host platform has one.
  final Widget? titleBar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Brings the playback service up for the app's lifetime. It watches the
    // controller and drives the real audio engine to match; watching it here,
    // in the always-mounted shell, is what keeps the engine watch alive.
    ref.watch(playbackServiceProvider);

    final Size size = MediaQuery.sizeOf(context);
    final bool isPhone = size.width < Tokens.breakpointPhone;

    final int currentIndex = navigationShell.currentIndex;
    // The highlight follows the route, not only the branch: Settings and the
    // Equalizer sit on top of a destination, so on those pages Settings is the
    // active item and no destination is highlighted.
    final bool settingsActive = onSettingsRoute(context);
    final int? highlighted = settingsActive ? null : currentIndex;
    final bool hasTrack = ref.watch(
      playbackProvider.select((PlaybackState state) => state.hasTrack),
    );
    final bool onNowPlaying = currentIndex == AppDestination.nowPlaying.index;

    // The page is the player on Now Playing, so the bar steps aside.
    final bool showNowPlayingBar = hasTrack && !onNowPlaying;

    void select(int index) =>
        navigationShell.goBranch(index, initialLocation: index == currentIndex);

    // Settings is a page on top of the current branch, so the reader keeps
    // their place, their Now Playing bar and their destination highlight.
    void openSettings() => context.go(settingsLocation(context));

    final Widget navigation = NavBottomBar(
      currentIndex: highlighted,
      settingsActive: settingsActive,
      onSelect: select,
      onOpenSettings: openSettings,
    );

    // The Android gesture inset the floating chrome must clear; on Windows
    // this is zero, so the pills simply float with their own margins.
    final double safeBottom = MediaQuery.paddingOf(context).bottom;

    final Widget body = isPhone
        ? Stack(
            children: <Widget>[
              // Pages own their scrolling; the shell owns the insets. The top
              // inset is handled by SafeArea (status bar, notch); the bottom
              // is computed from the floating chrome below.
              Positioned.fill(
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: EdgeInsets.only(
                      // Nav pill's outer bottom margin + the pill, plus the
                      // mini player above it when there is a track, plus
                      // breathing room for the page content.
                      bottom:
                          safeBottom +
                          Tokens.s12 +
                          Tokens.navBarHeight +
                          (showNowPlayingBar
                              ? Tokens.s8 + Tokens.nowPlayingBarHeight
                              : 0) +
                          Tokens.s16,
                    ),
                    child: navigationShell,
                  ),
                ),
              ),
              // The mini player floats just above the nav pill.
              if (showNowPlayingBar)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom:
                      safeBottom +
                      Tokens.s12 +
                      Tokens.navBarHeight +
                      Tokens.s8,
                  child: const NowPlayingBar(),
                ),
              // The nav pill anchors to the very bottom; SafeArea inside the
              // slot lifts it off Android's gesture zone.
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SafeArea(top: false, child: navigation),
              ),
            ],
          )
        : Stack(
            children: <Widget>[
              // The tab bar floats in the top strip and the Now Playing bar
              // in the bottom gap; reserving both here keeps the floating
              // chrome off the content without every page knowing they exist.
              Positioned.fill(
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: EdgeInsets.only(
                      top: Tokens.shellTopInset,
                      bottom: showNowPlayingBar
                          ? Tokens.nowPlayingBarHeight + Tokens.s16 * 2
                          : 0,
                    ),
                    child: navigationShell,
                  ),
                ),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  bottom: false,
                  child: NavTabBar(
                    currentIndex: highlighted,
                    settingsActive: settingsActive,
                    onSelect: select,
                    onOpenSettings: openSettings,
                  ),
                ),
              ),
              // The floating pill: centred on the page gutters, held a margin
              // off the window bottom, capped at the content width so it
              // never sprawls across an ultrawide window.
              if (showNowPlayingBar)
                Positioned(
                  left: Tokens.pageMarginDesktop,
                  right: Tokens.pageMarginDesktop,
                  bottom: Tokens.s16,
                  child: Align(
                    alignment: AlignmentDirectional.bottomCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: Tokens.contentMaxWidth,
                      ),
                      child: const NowPlayingBar(),
                    ),
                  ),
                ),
            ],
          );

    return Scaffold(
      backgroundColor: Tokens.transparent,
      // The ambient layer sits behind everything the shell draws: the app's
      // single artwork-derived surface. The veil on top of it is what keeps
      // the chrome readable, so no page paints a background of its own.
      body: Stack(
        children: <Widget>[
          const Positioned.fill(child: AmbientBackdrop()),
          Column(
            children: <Widget>[
              ?titleBar,
              Expanded(child: _GlobalShortcuts(child: body)),
            ],
          ),
        ],
      ),
    );
  }
}

/// The app's global keyboard shortcuts (spec: Keyboard shortcuts).
///
/// They are deliberately guarded: Space and the arrow keys are ignored while a
/// text field has focus, so typing a search query never toggles playback or
/// jumps the position. Ctrl+K is a modifier shortcut and works from anywhere.
class _GlobalShortcuts extends ConsumerWidget {
  const _GlobalShortcuts({required this.child});

  final Widget child;

  static const Duration _seekStep = Duration(seconds: 5);

  bool _isTyping() {
    final BuildContext? context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    return context.widget is EditableText ||
        context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  KeyEventResult _onKey(BuildContext context, WidgetRef ref, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (HardwareKeyboard.instance.isControlPressed &&
        event.logicalKey == LogicalKeyboardKey.keyK) {
      context.go(AppDestination.search.path);
      ref.read(searchFocusRequestProvider.notifier).request();
      return KeyEventResult.handled;
    }

    // Everything below would be wrong to trigger while typing.
    if (_isTyping()) return KeyEventResult.ignored;

    final PlaybackController controller = ref.read(playbackProvider.notifier);
    final PlaybackState state = ref.read(playbackProvider);

    if (event.logicalKey == LogicalKeyboardKey.space) {
      controller.togglePlayPause();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight && state.canSeek) {
      controller.seek(state.position + _seekStep);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft && state.canSeek) {
      controller.seek(state.position - _seekStep);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Focus(
      // The scope must not take focus away from whatever the user is using, so
      // it is canRequestFocus: false and only observes events that bubble up.
      canRequestFocus: false,
      onKeyEvent: (FocusNode node, KeyEvent event) =>
          _onKey(context, ref, event),
      child: child,
    );
  }
}
