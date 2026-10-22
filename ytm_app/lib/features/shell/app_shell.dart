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
    // Only the Now Playing page itself displaces the mini player; its sub-
    // pages (Queue, Equalizer) keep the bar like every other page.
    final bool onNowPlayingPage = onNowPlayingPageRoute(context);

    // The page is the player on Now Playing, so the bar steps aside.
    final bool showNowPlayingBar = hasTrack && !onNowPlayingPage;

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

    // How much chrome floats over the bottom of the content: the last strip
    // of every page scrolls beneath it while it keeps running.
    final double chromeZone;
    final double msafeBottom = isPhone ? safeBottom : 0;
    final double clearance;
    if (isPhone) {
      chromeZone =
          Tokens.s12 +
          Tokens.navBarHeight +
          (showNowPlayingBar ? Tokens.s8 + Tokens.nowPlayingBarHeight : 0);
      clearance = msafeBottom + chromeZone + Tokens.s16;
    } else {
      chromeZone = showNowPlayingBar
          ? Tokens.nowPlayingBarHeight + Tokens.s16 * 2
          : 0;
      clearance = chromeZone;
    }

    final Widget body = isPhone
        ? Stack(
            children: <Widget>[
              // Pages own their scrolling; the shell owns the insets. Content
              // runs under the floating chrome — the scrollable's own bottom
              // padding (bottom clearance) lifts the last rows above it — and
              // the fade mask below blends the page into the base before the
              // glass band. SafeArea handles the status bar / notch.
              Positioned.fill(
                child: SafeArea(
                  bottom: false,
                  child: ShellClearance(
                    bottom: clearance,
                    child: navigationShell,
                  ),
                ),
              ),
              _BottomFade(height: msafeBottom + chromeZone + Tokens.s48),
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
              // The tab bar floats in the reserved top strip; the Now Playing
              // bar floats over the content's bottom edge instead of taking a
              // column, so pages scroll beneath it.
              Positioned.fill(
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.only(top: Tokens.shellTopInset),
                    child: ShellClearance(
                      bottom: clearance,
                      child: navigationShell,
                    ),
                  ),
                ),
              ),
              if (showNowPlayingBar)
                _BottomFade(
                  height: Tokens.nowPlayingBarHeight + Tokens.s16 * 2 + Tokens.s48,
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

/// The extra bottom padding a page's scrollable must carry so its last rows
/// can scroll clear of the floating Now Playing bar and navigation.
///
/// The shell decides the number (it knows the chrome); the pages consume it
/// and own everything else about their scrolling. Pages that never scroll —
/// Now Playing — read it as the space their controls must stay clear of.
@immutable
class ShellClearance extends InheritedWidget {
  const ShellClearance({
    super.key,
    required this.bottom,
    required super.child,
  });

  /// Bottom padding in logical pixels the page content should keep free.
  final double bottom;

  /// The clearance provided by the nearest shell; zero outside the shell.
  static double of(BuildContext context) {
    final ShellClearance? shell = context
        .dependOnInheritedWidgetOfExactType<ShellClearance>();
    return shell?.bottom ?? 0;
  }

  @override
  bool updateShouldNotify(ShellClearance oldWidget) =>
      oldWidget.bottom != bottom;
}

/// A soft fade that blends scrolling content into the dark base before it
/// passes under the floating glass chrome — the page melting away rather than
/// hard-cutting at the band's top edge.
class _BottomFade extends StatelessWidget {
  const _BottomFade({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      height: height,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: const <Color>[Tokens.bg, Tokens.transparent],
              stops: <double>[0.0, 1.0],
            ),
          ),
        ),
      ),
    );
  }
}
