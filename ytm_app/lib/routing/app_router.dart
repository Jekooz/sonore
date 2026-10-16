import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../data/models.dart';
import '../features/collection/collection_screen.dart';
import '../features/equalizer/equalizer_screen.dart';
import '../features/home/home_screen.dart';
import '../features/library/library_screen.dart';
import '../features/lyrics/lyrics_screen.dart';
import '../features/now_playing/now_playing_screen.dart';
import '../features/search/search_screen.dart';
import '../features/queue/queue_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/shell/app_shell.dart';
import '../theme/tokens.dart';
import '../ui/screen_states.dart';
import '../ui/specimen.dart';
import 'destinations.dart';

/// Route of the design-system catalogue. It stays mounted so the Phase 2
/// primitives remain reviewable and golden-tested, but it is not a product
/// destination and has no nav entry.
const String devCataloguePath = '/dev';

/// Builds the app router.
///
/// [titleBar] is injected rather than created here so the Windows chrome stays
/// out of the widget tree on platforms (and in tests) that have no window to
/// control.
GoRouter createAppRouter({
  Widget? titleBar,
  String initialLocation = '/home',
}) {
  return GoRouter(
    initialLocation: initialLocation,
    routes: <RouteBase>[
      StatefulShellRoute.indexedStack(
        builder: (
          BuildContext context,
          GoRouterState state,
          StatefulNavigationShell navigationShell,
        ) =>
            AppShell(navigationShell: navigationShell, titleBar: titleBar),
        branches: <StatefulShellBranch>[
          _branch(AppDestination.home, (_, _) => const HomeScreen()),
          _branch(AppDestination.search, (_, _) => const SearchScreen()),
          _branch(AppDestination.library, (_, _) => const LibraryScreen()),
          _branch(AppDestination.nowPlaying, (_, _) => const NowPlayingScreen()),
        ],
      ),
      GoRoute(
        path: devCataloguePath,
        builder: (_, _) => const Scaffold(
          backgroundColor: Tokens.bg,
          body: SafeArea(child: SpecimenBoard()),
        ),
      ),
    ],
  );
}

/// One destination plus the pages that open on top of it.
///
/// Collection pages are nested inside every branch rather than being a branch of
/// their own. A shell branch's default location may not take parameters (go_router
/// asserts this), and nesting keeps what matters: the adaptive navigation and the
/// mini player stay on screen while browsing, the destination the page was opened
/// from stays highlighted, and Back pops to it.
///
/// The path is therefore `<destination>/collection/<kind>/<id>`, e.g.
/// `/library/collection/album/MPREb_…`.
StatefulShellBranch _branch(
  AppDestination destination,
  Widget Function(BuildContext, GoRouterState) builder,
) {
  return StatefulShellBranch(
    routes: <RouteBase>[
      GoRoute(
        path: destination.path,
        builder: builder,
        routes: <RouteBase>[
          GoRoute(
            path: 'collection/:kind/:id',
            builder: (BuildContext context, GoRouterState state) {
              final CollectionRef? target = CollectionRef.fromRoute(
                state.pathParameters['kind'],
                state.pathParameters['id'],
              );
              if (target == null) return const _UnknownCollection();
              return CollectionScreen(target: target);
            },
          ),
          // Settings sits in every branch so opening it keeps the destination
          // the reader came from highlighted and leaves the mini player where
          // it is — the same reason collections are nested this way.
          GoRoute(
            path: 'settings',
            builder: (_, _) => const SettingsScreen(),
          ),
          // Now Playing's three detail screens. Design.md sections F, G and H
          // place the Queue, Lyrics and the Equalizer off Now Playing, not in
          // the nav bar.
          if (destination == AppDestination.nowPlaying) ...<RouteBase>[
            GoRoute(
              path: 'queue',
              builder: (_, _) => const QueueScreen(),
            ),
            GoRoute(
              path: 'lyrics',
              builder: (_, _) => const LyricsScreen(),
            ),
            GoRoute(
              path: 'equalizer',
              builder: (_, _) => const EqualizerScreen(),
            ),
          ],
        ],
      ),
    ],
  );
}

/// The path of a collection page inside the branch the user is currently in.
///
/// Opening a collection stays in the current destination, which is what keeps
/// the nav item highlighted and gives Back something to pop to.
String collectionLocation(BuildContext context, CollectionRef target) {
  final String location = GoRouterState.of(context).matchedLocation;
  final AppDestination destination =
      AppDestination.forPath(location) ?? AppDestination.home;
  return '${destination.path}/collection/${target.kind.name}'
      '/${Uri.encodeComponent(target.id)}';
}

/// Settings inside the destination the reader is currently in.
String settingsLocation(BuildContext context) {
  final String location = GoRouterState.of(context).matchedLocation;
  final AppDestination destination =
      AppDestination.forPath(location) ?? AppDestination.home;
  return '${destination.path}/settings';
}

/// Whether the page on screen is one the Settings item stands for.
///
/// Settings and the Equalizer are opened *on top of* a destination rather than
/// being destinations of their own, so the branch index alone would keep the
/// destination behind them highlighted — opening the Equalizer from Now Playing
/// left "Now Playing" lit while the reader was on the Equalizer. The active nav
/// item follows the route instead: on these two pages Settings is active and no
/// destination is.
bool onSettingsRoute(BuildContext context) {
  final String location = GoRouterState.of(context).matchedLocation;
  return location.endsWith('/settings') || location.endsWith('/equalizer');
}

/// A collection path whose kind or id is not recognised.
///
/// Reachable only by following a malformed link; it says so plainly instead of
/// rendering an empty page that looks like a loading bug.
class _UnknownCollection extends StatelessWidget {
  const _UnknownCollection();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Tokens.bg,
      body: SafeArea(
        child: StateMessage(
          message: 'That page does not exist.',
          footnote: 'The link points at something this app cannot open.',
        ),
      ),
    );
  }
}
