import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../theme/icons.dart';
import '../../theme/tokens.dart';
import '../../ui/data_states.dart';
import '../../ui/media_rows.dart';
import '../../ui/pressable.dart';
import '../../ui/screen_states.dart';
import 'search_controller.dart';

/// The Search destination.
///
/// Spec section 3.B: a search field at the top, search-as-you-type with a
/// 300 ms debounce, recent searches before a query, results grouped into Songs,
/// Albums, Artists and Playlists, "No results" with the query text rather than a
/// blank page, and Retry when a request fails.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  late final TextEditingController _field = TextEditingController();

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final SearchState state = ref.watch(searchProvider);
    final MediaSearchController controller =
        ref.read(searchProvider.notifier);
    final bool isDesktop =
        MediaQuery.sizeOf(context).width >= Tokens.breakpointDesktop;
    final double margin =
        isDesktop ? Tokens.pageMarginDesktop : Tokens.pageMarginPhone;

    // Ctrl+K focuses the field; the node lives in the notifier so the shell's
    // shortcut can reach it without a global key. The request is handled after
    // the frame, once the field is actually mounted.
    final FocusNode focusNode = ref.watch(searchFocusNodeProvider);
    if (ref.watch(searchFocusRequestProvider)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        focusNode.requestFocus();
        ref.read(searchFocusRequestProvider.notifier).clear();
      });
    }

    return ConnectionGate(
      loading: const ListSkeleton(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.fromLTRB(
              margin,
              Tokens.s16,
              margin,
              Tokens.s8,
            ),
            child: _SearchField(
              controller: _field,
              focusNode: focusNode,
              hint: 'Search songs, albums, artists, playlists',
              onChanged: controller.onQueryChanged,
              onSubmitted: controller.submit,
              onClear: () {
                _field.clear();
                controller.clearQuery();
                focusNode.requestFocus();
              },
            ),
          ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: margin),
              child: _SearchBody(state: state, controller: controller),
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.onChanged,
    required this.onSubmitted,
    required this.onClear,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: Tokens.surface,
        shape: Tokens.shapeFor(Tokens.rCard),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Tokens.s12),
        child: Row(
          children: <Widget>[
            const Icon(
              AppIcons.magnifyingGlass,
              size: Tokens.iconSize,
              color: Tokens.textSecondary,
            ),
            const SizedBox(width: Tokens.s8),
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                onChanged: onChanged,
                onSubmitted: onSubmitted,
                style: Tokens.rowTitle,
                cursorColor: Tokens.accent,
                decoration: InputDecoration(
                  hintText: hint,
                  hintStyle: Tokens.subtitle,
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(vertical: Tokens.s16),
                ),
              ),
            ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (BuildContext context, TextEditingValue value, _) {
                if (value.text.isEmpty) return const SizedBox.shrink();
                return Pressable(
                  semanticLabel: 'Clear search',
                  onTap: onClear,
                  child: const Icon(
                    AppIcons.close,
                    size: Tokens.iconSize,
                    color: Tokens.textSecondary,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchBody extends StatelessWidget {
  const _SearchBody({required this.state, required this.controller});

  final SearchState state;
  final MediaSearchController controller;

  @override
  Widget build(BuildContext context) {
    if (state.error != null) {
      return StateMessage(
        message: state.error!,
        actionLabel: 'Try again',
        actionIcon: AppIcons.arrowClockwise,
        onAction: controller.retry,
      );
    }

    if (!state.hasQuery) {
      return _RecentSearches(
        recent: state.recent,
        onSelected: (String query) => controller.submit(query),
      );
    }

    if (state.isEmptyResult) {
      return StateMessage(
        message: 'No results for “${state.query.trim()}”.',
        footnote: 'Check the spelling, or try a different artist or album.',
      );
    }

    // While a newer query is in flight the previous results stay on screen:
    // they are replaced only when the newest response lands, so typing does not
    // flash a skeleton on every keystroke.
    final SearchResults? results = state.results;
    if (results == null) return const ListSkeleton();

    return _SearchResultsList(results: results);
  }
}

class _RecentSearches extends StatelessWidget {
  const _RecentSearches({required this.recent, required this.onSelected});

  final List<String> recent;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    if (recent.isEmpty) {
      return const StateMessage(
        message: 'Search YouTube Music.',
        footnote: 'Find a song, album, artist or playlist to start listening.',
      );
    }

    return ListView(
      padding: const EdgeInsets.only(top: Tokens.s8),
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.symmetric(vertical: Tokens.s8),
          child: Text('Recent searches', style: Tokens.sectionHeader),
        ),
        for (final String query in recent)
          Pressable(
            onTap: () => onSelected(query),
            child: SizedBox(
              height: Tokens.minTouchTarget,
              child: Row(
                children: <Widget>[
                  const Icon(
                    AppIcons.clockCounterClockwise,
                    size: Tokens.iconSize,
                    color: Tokens.textMuted,
                  ),
                  const SizedBox(width: Tokens.s12),
                  Expanded(
                    child: Text(
                      query,
                      style: Tokens.rowTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _SearchResultsList extends StatelessWidget {
  const _SearchResultsList({required this.results});

  final SearchResults results;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: Tokens.shellBottomInset),
      children: <Widget>[
        _Group(title: 'Songs', items: results.songs),
        _Group(title: 'Albums', items: results.albums),
        _Group(title: 'Artists', items: results.artists),
        _Group(title: 'Playlists', items: results.playlists),
      ],
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.title, required this.items});

  final String title;
  final List<MediaItem> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: Tokens.s16, bottom: Tokens.s8),
          child: Text(title, style: Tokens.sectionHeader),
        ),
        for (final MediaItem item in items)
          MediaRow(item: item, siblings: items),
      ],
    );
  }
}
