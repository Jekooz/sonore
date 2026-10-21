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
/// - the navigation menu is the only floating chrome. Under
///   [Tokens.breakpointPhone] it is the compact glass bottom pill; at
///   [Tokens.breakpointPhone] and wider it is the floating glass top tab bar;
/// - the Now Playing bar is docked, not floating. It is a normal child of the
///   layout column at the bottom of the content area — above the phone
///   navigation menu, flush with the window bottom on wide layouts — so it can
///   never hover over content or overlap the navigation.
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

    final Widget body = isPhone
        ? Column(
            children: <Widget>[
              // Pages own their scrolling; the shell owns the system insets.
              // The top inset keeps content out of the Android status bar and
              // any notch, while the bottom is handled by the navigation pill.
              Expanded(child: SafeArea(bottom: false, child: navigationShell)),
              // Docked: it sits in the layout above the floating navigation
              // pill, not over the page.
              if (showNowPlayingBar) const NowPlayingBar(),
              SafeArea(top: false, child: navigation),
            ],
          )
        : Column(
            children: <Widget>[
              Expanded(
                child: Stack(
                  children: <Widget>[
                    // The tab bar floats in this strip; reserving it here keeps
                    // the floating chrome off the content without every page
                    // having to know it exists. The Now Playing bar no longer
                    // needs a scroll inset because it takes layout space below.
                    Positioned.fill(
                      child: SafeArea(
                        bottom: false,
                        child: Padding(
                          padding: const EdgeInsets.only(
                            top: Tokens.shellTopInset,
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
                  ],
                ),
              ),
              // Anchored to the bottom of the content area. SafeArea only
              // reserves the Android gesture inset; on Windows this is zero,
              // so the bar is flush with the window edge.
              if (showNowPlayingBar)
                const SafeArea(top: false, child: NowPlayingBar()),
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
