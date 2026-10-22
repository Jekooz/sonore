import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../audio/track.dart';
import '../../data/models.dart';
import '../../data/ytm_repository.dart';
import '../../theme/tokens.dart';
import '../../ui/data_states.dart';
import '../../ui/media_rows.dart';
import '../shell/app_shell.dart';
import 'hero_banner.dart';
import 'popular_rail.dart';

/// The Home destination: the hero, the real personalized rails, and the
/// Popular rail.
///
/// Order is the approved layout's: the featured release first, then the existing
/// shelves in the order the service returned them. Rails the service returns
/// empty are dropped before they reach here, so a rail always has cards, and the
/// page still supports a loading skeleton, a helpful empty state, retry on error
/// and a distinct offline state.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ConnectionGate(
      loading: const ListSkeleton(),
      child: DataStateView<List<HomeRow>>(
        value: ref.watch(homeProvider),
        onRetry: () => ref.invalidate(homeProvider),
        isEmpty: (List<HomeRow> rows) => rows.isEmpty,
        emptyMessage: 'Nothing to show on Home yet.',
        emptyFootnote: 'Listen to a few tracks and your mixes will appear here.',
        loading: const ListSkeleton(),
        data: (List<HomeRow> rows) => _HomeContent(rows: rows),
      ),
    );
  }
}

/// The featured release: the first album the feed carries, or the first artist
/// when it carries no album. Null when it carries neither, in which case the
/// hero is simply not rendered.
MediaItem? featuredRelease(List<HomeRow> rows) {
  MediaItem? artist;
  for (final HomeRow row in rows) {
    for (final MediaItem item in row.items) {
      if (item.collection == null) continue;
      if (item.kind == MediaKind.album) return item;
      if (item.kind == MediaKind.artist && artist == null) artist = item;
    }
  }
  return artist;
}

/// The tracks behind the Popular rail.
///
/// The sidecar exposes no dedicated charts endpoint, so the honest source is the
/// feed itself: every playable row it returned, de-duplicated by track id and
/// kept in service order. The rail is therefore hidden — never filled with
/// invented entries — when the feed carries nothing to play.
List<MediaItem> popularTracks(List<HomeRow> rows, {int limit = 8}) {
  final List<MediaItem> out = <MediaItem>[];
  final Set<String> seen = <String>{};
  for (final HomeRow row in rows) {
    for (final MediaItem item in row.items) {
      final Track? track = item.track;
      if (track == null || !seen.add(track.id)) continue;
      out.add(item);
      if (out.length >= limit) return out;
    }
  }
  return out;
}

class _HomeContent extends ConsumerWidget {
  const _HomeContent({required this.rows});

  final List<HomeRow> rows;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool isDesktop =
        MediaQuery.sizeOf(context).width >= Tokens.breakpointDesktop;
    final double margin = Tokens.pageMargin(
      MediaQuery.sizeOf(context).width,
    );
    final MediaItem? featured = featuredRelease(rows);
    final List<MediaItem> popular = popularTracks(rows);
    // Desktop only; and only when there is a real track to list.
    final bool showPopular = isDesktop && popular.isNotEmpty;

    // Ultrawide guard: the whole content row — rails and the Popular third
    // column — stops growing at [Tokens.contentMaxWidth] and centers, so line
    // lengths stay readable on a 1920 window.
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: Tokens.contentMaxWidth),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: RefreshIndicator(
                color: Tokens.text,
                backgroundColor: Tokens.surfaceRaised,
                onRefresh: () async {
                  ref.invalidate(connectionProvider);
                  ref.invalidate(homeProvider);
                  await ref.read(homeProvider.future);
                },
                // A Column, not a lazy list: a handful of rails is cheap, and
                // it keeps every shelf the service returned mounted — the
                // hero must not be able to push a later rail out of the tree.
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(
                    margin,
                    Tokens.s24,
                    margin,
                    // The last rail must scroll clear of the floating bar
                    // while it keeps running beneath it.
                    Tokens.s24 + ShellClearance.of(context),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.only(bottom: Tokens.s16),
                        child: Text(
                          'Good evening',
                          style: isDesktop
                              ? Tokens.pageTitleDesktop
                              : Tokens.pageTitle,
                        ),
                      ),
                      if (featured != null) HomeHeroBanner(item: featured),
                      for (final HomeRow row in rows) _HomeRail(row: row),
                    ],
                  ),
                ),
              ),
            ),
            if (showPopular) PopularRail(tracks: popular),
          ],
        ),
      ),
    );
  }
}

class _HomeRail extends StatelessWidget {
  const _HomeRail({required this.row});

  final HomeRow row;

  @override
  Widget build(BuildContext context) {
    // A rail the service short-changed looks broken, not curated: one or two
    // cards in an otherwise full grid reads as an error state. Sections show
    // only with enough content to fill the layout.
    if (row.items.length < Tokens.minRailItems) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: Tokens.s24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(row.title, style: Tokens.sectionHeader),
          const SizedBox(height: Tokens.s12),
          // The trailing cards melt out under the page edge instead of
          // hard-cutting against the gutter.
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final double width = constraints.maxWidth;
              // A s32-wide fade window at the trailing edge.
              final double fadeStart = (1 - Tokens.s32 / width).clamp(0.0, 1.0);
              return ShaderMask(
                shaderCallback: (Rect bounds) => LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: const <Color>[Tokens.text, Tokens.text, Tokens.transparent],
                  stops: <double>[0.0, fadeStart, 1.0],
                ).createShader(bounds),
                blendMode: BlendMode.dstIn,
                child: SizedBox(
                  height: Tokens.railCardHeight,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: row.items.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(width: Tokens.s16),
                    itemBuilder: (BuildContext context, int index) => MediaCard(
                      item: row.items[index],
                      siblings: row.items,
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
