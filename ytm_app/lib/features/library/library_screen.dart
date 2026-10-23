import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../audio/playback_controller.dart';
import '../../audio/playback_state.dart';
import '../../data/models.dart';
import '../../data/ytm_repository.dart';
import '../../theme/icons.dart';
import '../../theme/tokens.dart';
import '../../ui/context_menu.dart';
import '../../ui/content_column.dart';
import '../../ui/data_states.dart';
import '../../ui/media_rows.dart';
import '../../ui/pressable.dart';
import '../shell/app_shell.dart';

/// How the current segment is ordered.
///
/// Spec: "The sort menu can contain only valid, implemented choices." The
/// sidecar exposes neither an added-date nor a played-date for these lists, so
/// offering "Recently added" or "Recently played" would be a lie. What is
/// genuinely implemented is the service's own order and an A–Z order.
enum LibrarySort {
  serviceOrder('Service order'),
  alphabetical('A–Z');

  const LibrarySort(this.label);

  final String label;
}

final NotifierProvider<LibrarySegmentController, LibrarySegment>
librarySegmentProvider =
    NotifierProvider<LibrarySegmentController, LibrarySegment>(
      LibrarySegmentController.new,
    );

class LibrarySegmentController extends Notifier<LibrarySegment> {
  @override
  LibrarySegment build() => LibrarySegment.playlists;

  void select(LibrarySegment segment) => state = segment;
}

final NotifierProvider<LibrarySortController, LibrarySort> librarySortProvider =
    NotifierProvider<LibrarySortController, LibrarySort>(
      LibrarySortController.new,
    );

class LibrarySortController extends Notifier<LibrarySort> {
  @override
  LibrarySort build() => LibrarySort.serviceOrder;

  void select(LibrarySort sort) => state = sort;
}

/// The Library destination: the user's real playlists, songs, albums and
/// artists from the sidecar.
class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final LibrarySegment segment = ref.watch(librarySegmentProvider);
    final LibrarySort sort = ref.watch(librarySortProvider);
    final bool isDesktop =
        MediaQuery.sizeOf(context).width >= Tokens.breakpointDesktop;
    final double margin = isDesktop
        ? Tokens.pageMarginDesktop
        : Tokens.pageMarginPhone;

    return ConnectionGate(
      loading: const ListSkeleton(),
      // The shared browsing column: Library centers like Search instead of
      // hugging the page margin on a 1920 window (round-2 leftover).
      child: ContentColumn(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: EdgeInsets.fromLTRB(
                margin,
                Tokens.s24,
                margin,
                Tokens.s12,
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'Library',
                      style: isDesktop
                          ? Tokens.pageTitleDesktop
                          : Tokens.pageTitle,
                    ),
                  ),
                  _SortControl(
                    sort: sort,
                    onSelected: (LibrarySort value) =>
                        ref.read(librarySortProvider.notifier).select(value),
                  ),
                ],
              ),
            ),
            _SegmentChips(selected: segment),
            Expanded(
              child: DataStateView<List<MediaItem>>(
                value: ref.watch(libraryProvider(segment)),
                onRetry: () => ref.invalidate(libraryProvider),
                isEmpty: (List<MediaItem> items) => items.isEmpty,
                // History is the app's own record, not a service library, so it
                // must not borrow the library's wording: nothing was "saved"
                // there, and an empty list means nothing has been played yet.
                emptyMessage: segment == LibrarySegment.history
                    ? 'Nothing played yet.'
                    : 'No ${segment.label.toLowerCase()} in your library.',
                emptyFootnote: segment == LibrarySegment.history
                    ? 'Tracks you play here appear in this list, newest first.'
                    : 'Anything you save in YouTube Music shows up here.',
                loading: const ListSkeleton(),
                data: (List<MediaItem> items) =>
                    _LibraryList(items: _sorted(items, sort), segment: segment),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static List<MediaItem> _sorted(List<MediaItem> items, LibrarySort sort) {
    if (sort == LibrarySort.serviceOrder) return items;
    final List<MediaItem> sorted = List<MediaItem>.of(items)
      ..sort(
        (MediaItem a, MediaItem b) =>
            a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      );
    return sorted;
  }
}

class _LibraryList extends ConsumerWidget {
  const _LibraryList({required this.items, required this.segment});

  final List<MediaItem> items;
  final LibrarySegment segment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool isDesktop =
        MediaQuery.sizeOf(context).width >= Tokens.breakpointDesktop;
    final double margin = isDesktop
        ? Tokens.pageMarginDesktop
        : Tokens.pageMarginPhone;
    // Watching just the current id keeps every row from rebuilding on each
    // position tick.
    final String? currentTrackId = ref.watch(
      playbackProvider.select((PlaybackState state) => state.current?.id),
    );

    return ListView.builder(
      padding: EdgeInsets.fromLTRB(
        margin,
        // A clear gap between the filter chips above and the first row: the
        // expanded content starts at its children's own edges otherwise.
        Tokens.s12,
        margin,
        Tokens.s24 + ShellClearance.of(context),
      ),
      itemCount: items.length,
      itemBuilder: (BuildContext context, int index) {
        final MediaItem item = items[index];
        return MediaRow(
          item: item,
          siblings: items,
          isPlaying: item.track != null && item.track!.id == currentTrackId,
        );
      },
    );
  }
}

class _SegmentChips extends ConsumerWidget {
  const _SegmentChips({required this.selected});

  final LibrarySegment selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool isDesktop =
        MediaQuery.sizeOf(context).width >= Tokens.breakpointDesktop;
    final double margin = isDesktop
        ? Tokens.pageMarginDesktop
        : Tokens.pageMarginPhone;

    return SizedBox(
      height: Tokens.minTouchTarget,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: margin),
        itemCount: LibrarySegment.values.length,
        separatorBuilder: (_, _) => const SizedBox(width: Tokens.s8),
        itemBuilder: (BuildContext context, int index) {
          final LibrarySegment segment = LibrarySegment.values[index];
          return _Chip(
            label: segment.label,
            selected: segment == selected,
            onTap: () =>
                ref.read(librarySegmentProvider.notifier).select(segment),
          );
        },
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Pressable(
        semanticLabel: label,
        onTap: onTap,
        child: AnimatedContainer(
          duration: Tokens.dPress,
          curve: Tokens.curvePress,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: Tokens.s16),
          decoration: ShapeDecoration(
            color: selected ? Tokens.borderStrong : Tokens.transparent,
            shape: Tokens.shapePill,
          ),
          child: Text(
            label,
            style: Tokens.subtitle.copyWith(
              color: selected ? Tokens.text : Tokens.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// The sort control. It opens the shared context menu, so the options match the
/// menus' look and only implemented orders are listed.
class _SortControl extends StatelessWidget {
  const _SortControl({required this.sort, required this.onSelected});

  final LibrarySort sort;
  final ValueChanged<LibrarySort> onSelected;

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (BuildContext sortContext) => Pressable(
        semanticLabel: 'Sort library: ${sort.label}',
        onTap: () => showContextMenuAt(sortContext, <ContextMenuEntry>[
          for (final LibrarySort option in LibrarySort.values)
            ContextMenuEntry(
              icon: option == sort
                  ? AppIcons.sortAscending
                  : AppIcons.listBullets,
              label: option == sort ? '${option.label} ✓' : option.label,
              onSelected: () => onSelected(option),
            ),
        ]),
        child: Row(
          children: <Widget>[
            const Icon(
              AppIcons.sortAscending,
              size: Tokens.iconSize,
              color: Tokens.textSecondary,
            ),
            const SizedBox(width: Tokens.s8),
            Text(sort.label, style: Tokens.subtitle),
          ],
        ),
      ),
    );
  }
}
