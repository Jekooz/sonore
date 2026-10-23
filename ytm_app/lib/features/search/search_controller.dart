import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../data/ytm_repository.dart';

/// The key recent queries persist under (cross-launch, platform store).
const String _kRecentSearches = 'search.recentQueries';
const int _recentLimit = 8;

/// Search's own state: the query, whether a request is in flight, the grouped
/// results and recent queries.
@immutable
class SearchState {
  const SearchState({
    this.query = '',
    this.results,
    this.isSearching = false,
    this.error,
    this.recent = const <String>[],
  });

  final String query;
  final SearchResults? results;
  final bool isSearching;

  /// A user-facing message, or null. Only the latest query's failures are kept.
  final String? error;

  /// Recent queries, most recent first.
  final List<String> recent;

  bool get hasQuery => query.trim().isNotEmpty;

  /// True once a search for the current query finished and found nothing.
  bool get isEmptyResult =>
      results != null && results!.isEmpty && !isSearching && hasQuery;

  SearchState copyWith({
    String? query,
    SearchResults? results,
    bool? isSearching,
    String? error,
    bool clearError = false,
    bool clearResults = false,
    List<String>? recent,
  }) {
    return SearchState(
      query: query ?? this.query,
      results: clearResults ? null : (results ?? this.results),
      isSearching: isSearching ?? this.isSearching,
      error: clearError ? null : (error ?? this.error),
      recent: recent ?? this.recent,
    );
  }
}

/// Drives search: 300 ms debounce, grouped results, and a guard that keeps a
/// slower response for an older query from overwriting a newer one (spec
/// section 3.B: "Stale results from an earlier query must not overwrite results
/// from a newer query").
class MediaSearchController extends Notifier<SearchState> {
  Timer? _debounce;

  /// Increments per issued request; a response is applied only if it is still
  /// the newest one.
  int _issued = 0;

  @override
  SearchState build() {
    ref.onDispose(() => _debounce?.cancel());
    _loadPersistedRecent();
    return const SearchState();
  }

  /// Restores the persisted recent queries. A store that fails to open (a
  /// test harness, a locked-down platform) keeps search session-scoped
  /// rather than failing the screen.
  Future<void> _loadPersistedRecent() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final List<String>? stored = prefs.getStringList(_kRecentSearches);
      if (stored == null || stored.isEmpty) return;
      state = SearchState(query: state.query, recent: stored);
    } catch (_) {
      // Session-scoped recents.
    }
  }

  /// Called as the user types: debounces, then searches.
  void onQueryChanged(String query) {
    _debounce?.cancel();
    final String trimmed = query.trim();

    if (trimmed.isEmpty) {
      // Clearing the field returns to recent searches immediately; no request
      // is in flight for an empty query.
      _issued++;
      state = SearchState(recent: state.recent);
      return;
    }

    state = state.copyWith(query: query, isSearching: true, clearError: true);
    _debounce = Timer(const Duration(milliseconds: 300), () => _run(trimmed));
  }

  /// Searches immediately (Enter, or a recent-search tap).
  Future<void> submit(String query) async {
    _debounce?.cancel();
    final String trimmed = query.trim();
    if (trimmed.isEmpty) return;
    state = state.copyWith(query: query, isSearching: true, clearError: true);
    await _run(trimmed);
  }

  Future<void> _run(String query) async {
    final int issued = ++_issued;
    try {
      final SearchResults results = await ref
          .read(ytmRepositoryProvider)
          .search(query);
      if (issued != _issued) return; // a newer query already answered
      state = state.copyWith(
        results: results,
        isSearching: false,
        clearError: true,
        recent: _withRecent(query),
      );
    } on YtmException catch (error) {
      if (issued != _issued) return;
      state = state.copyWith(isSearching: false, error: error.message);
    }
  }

  /// Retries the current query.
  Future<void> retry() => submit(state.query);

  void clearQuery() {
    _debounce?.cancel();
    _issued++;
    state = SearchState(recent: state.recent);
  }

  List<String> _withRecent(String query) {
    final List<String> next = <String>[
      query,
      ...state.recent.where((String entry) => entry != query),
    ];
    final List<String> capped = next.take(_recentLimit).toList(growable: false);
    _persist(capped);
    return capped;
  }

  /// Writes the list straight through on every change, so a restarted app
  /// reopens with the last few queries.
  Future<void> _persist(List<String> recent) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kRecentSearches, recent);
    } catch (_) {
      // Session-scoped recents.
    }
  }
}

final NotifierProvider<MediaSearchController, SearchState> searchProvider =
    NotifierProvider<MediaSearchController, SearchState>(
      MediaSearchController.new,
    );

/// The search field's focus node, so Ctrl+K can move focus into it from
/// anywhere (spec: keyboard shortcuts).
final NotifierProvider<SearchFocusNode, FocusNode> searchFocusNodeProvider =
    NotifierProvider<SearchFocusNode, FocusNode>(SearchFocusNode.new);

class SearchFocusNode extends Notifier<FocusNode> {
  @override
  FocusNode build() {
    final FocusNode node = FocusNode(debugLabel: 'search');
    ref.onDispose(node.dispose);
    return node;
  }
}

/// Set by Ctrl+K. The shell raises it and the search screen takes focus as soon
/// as it is on screen, because at the moment the shortcut fires the field may
/// not be mounted yet.
final NotifierProvider<SearchFocusRequest, bool> searchFocusRequestProvider =
    NotifierProvider<SearchFocusRequest, bool>(SearchFocusRequest.new);

class SearchFocusRequest extends Notifier<bool> {
  @override
  bool build() => false;

  void request() => state = true;

  /// Consumed once the field has focus.
  void clear() => state = false;
}
