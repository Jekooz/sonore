import 'package:flutter/widgets.dart';

import '../theme/icons.dart';

/// The four destinations of the app shell.
///
/// Spec: "Four destinations: Home, Search, Library, Now Playing." The filled
/// variant of each glyph marks the active destination.
enum AppDestination {
  home('/home', 'Home', AppIcons.house, AppIcons.houseFill),
  search('/search', 'Search', AppIcons.magnifyingGlass, AppIcons.magnifyingGlassFill),
  library('/library', 'Library', AppIcons.listBullets, AppIcons.listBulletsFill),
  nowPlaying(
    '/now-playing',
    'Now Playing',
    AppIcons.musicNotes,
    AppIcons.musicNotesFill,
  );

  const AppDestination(this.path, this.label, this.icon, this.activeIcon);

  final String path;
  final String label;
  final IconData icon;
  final IconData activeIcon;

  /// Matches a router location to its destination, or null for routes outside
  /// the shell (such as the development catalogue).
  static AppDestination? forPath(String location) {
    for (final AppDestination destination in AppDestination.values) {
      if (location.startsWith(destination.path)) return destination;
    }
    return null;
  }
}
