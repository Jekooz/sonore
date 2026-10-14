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
import '../search/search_controller.dart';
import 'mini_player.dart';
import 'nav_bottom_bar.dart';
import 'nav_rail.dart';

/// The adaptive shell: navigation, the responsive content area and the
/// persistent mini player all live here, so no page owns the player.
///
/// Layout rules from the spec:
/// - under [Tokens.breakpointPhone]: glass bottom bar, mini player pill docked
///   above it;
/// - [Tokens.breakpointPhone]..[Tokens.breakpointDesktop): 72px icon rail;
/// - [Tokens.breakpointDesktop] and wider: 220px sidebar, mini player as a
///   full-width bar floating over the content, so content scrolls under it.
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
    final bool isDesktop = size.width >= Tokens.breakpointDesktop;

    final int currentIndex = navigationShell.currentIndex;
    final bool hasTrack = ref.watch(
      playbackProvider.select((PlaybackState state) => state.hasTrack),
    );
    final bool onNowPlaying =
        currentIndex == AppDestination.nowPlaying.index;

    // The page is the player on Now Playing, so the mini player steps aside.
    final bool showMiniPlayer = hasTrack && !onNowPlaying;

    void select(int index) => navigationShell.goBranch(
          index,
          initialLocation: index == currentIndex,
        );

    // Settings is a page on top of the current branch, so the reader keeps
    // their place, their mini player and their destination highlight.
    void openSettings() => context.go(settingsLocation(context));

    final Widget body = isPhone
        ? Column(
            children: <Widget>[
              Expanded(child: navigationShell),
              if (showMiniPlayer)
                const Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: Tokens.pageMarginPhone,
                  ),
                  child: MiniPlayer(fullWidth: true),
                ),
              SafeArea(
                top: false,
                child: NavBottomBar(
                  currentIndex: currentIndex,
                  onSelect: select,
                  onOpenSettings: openSettings,
                ),
              ),
            ],
          )
        : Row(
            children: <Widget>[
              NavRail(
                expanded: isDesktop,
                currentIndex: currentIndex,
                onSelect: select,
                onOpenSettings: openSettings,
              ),
              Expanded(
                child: Stack(
                  children: <Widget>[
                    navigationShell,
                    if (showMiniPlayer)
                      const Positioned(
                        left: Tokens.s24,
                        right: Tokens.s24,
                        bottom: Tokens.s16,
                        child: MiniPlayer(fullWidth: true),
                      ),
                  ],
                ),
              ),
            ],
          );

    return Scaffold(
      backgroundColor: Tokens.bg,
      body: Column(
        children: <Widget>[
          ?titleBar,
          Expanded(
            child: _GlobalShortcuts(child: body),
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
