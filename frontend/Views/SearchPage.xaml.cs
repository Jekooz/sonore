using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using YtMusicClient.Services;

namespace YtMusicClient.Views
{
    /// <summary>
    /// Search across YouTube Music via the backend /search endpoint. Typeahead:
    /// each keystroke restarts a 300 ms debounce, then the query is searched and
    /// the results update in place (virtualized ListView). Every result row
    /// carries its real credit line (artists[]/artist/author) and duration.
    ///
    /// Categories: the chip row is the real YT Music search tabs (Songs / Videos
    /// / Albums / Artists / Playlists) — clicking a chip re-runs the query
    /// through that backend filter (server-side category, not client filtering).
    ///
    /// Recent searches: the last queries are remembered locally (this device
    /// only) and offered in a flyout next to the box; clicking one re-runs it.
    /// </summary>
    public sealed partial class SearchPage : Page
    {
        private int _searchGeneration;
        private List<SearchResultItemView> _allResults = new();
        private string _activeFilter;          // null = All; else the backend filter id
        private CancellationTokenSource _debounceCts;

        /// <summary>The currently displayed results — bound to the ListView.</summary>
        public ObservableCollection<SearchResultItemView> _displayResults = new();

        public SearchPage()
        {
            InitializeComponent();
        }

        private void SearchBox_KeyDown(object sender, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs e)
        {
            if (e.Key == Windows.System.VirtualKey.Enter)
            {
                HistoryFlyout.Hide();
                _ = RunSearchAsync(SearchBox.Text?.Trim(), SaveToHistory: true);
                e.Handled = true;
            }
        }

        /// <summary>
        /// Typeahead: each keystroke cancels any in-flight debounce and starts a
        /// new 300 ms timer. When the timer fires, the current text is searched
        /// (unless a newer keystroke already superseded it). The committed query
        /// is remembered in the local recent-searches list.
        /// </summary>
        private async void SearchBox_TextChanged(object sender, TextChangedEventArgs e)
        {
            _debounceCts?.Cancel();
            _debounceCts = new CancellationTokenSource();
            var token = _debounceCts.Token;

            try
            {
                await Task.Delay(300, token);
            }
            catch (TaskCanceledException)
            {
                return; // a newer keystroke superseded this debounce
            }

            await RunSearchAsync(SearchBox.Text?.Trim(), SaveToHistory: true);
        }

        private void SearchBox_GotFocus(object sender, RoutedEventArgs e)
        {
            // After a chip-driven search the chips stay put; opening history is
            // a deliberate click on the clock icon (kept in its own flyout so
            // chips never jump when focus moves).
        }

        /// <summary>
        /// Result click. Song/video results carry a videoId and play straight away,
        /// with the visible (filtered) results as the queue. Album/playlist/artist
        /// results carry only an id, so the backend resolves them and their
        /// tracklist opens — the user picks the track, instead of the result
        /// silently doing nothing (or forcing track 1).
        /// </summary>
        private async void Result_Click(object sender, RoutedEventArgs e)
        {
            if ((sender as FrameworkElement)?.DataContext is not SearchResultItemView item)
                return;

            if (!string.IsNullOrEmpty(item.VideoId))
            {
                List<QueueTrack> visibleQueue = ResultsList.ItemsSource is IEnumerable<SearchResultItemView> visible
                    ? visible.Where(r => !string.IsNullOrEmpty(r.VideoId))
                        .Select(r => new QueueTrack(r.VideoId, r.Title, r.Artist, r.ThumbnailUrl))
                        .ToList()
                    : new List<QueueTrack>();
                if (visibleQueue.Count == 0)
                    visibleQueue.Add(new QueueTrack(item.VideoId, item.Title, item.Artist, item.ThumbnailUrl));

                await App.Playback.PlayAsync(visibleQueue, visibleQueue.FindIndex(t => t.VideoId == item.VideoId));
                if (App.Window is MainWindow mainWindow)
                    mainWindow.ShowNowPlaying();
                return;
            }

            var detail = await CollectionQueue.ResolveAsync(item.BrowseId, item.PlaylistId);
            if (detail == null)
                return;

            if (App.Window is MainWindow window)
                window.ShowCollection(new CollectionRequest(detail, item.ThumbnailUrl));
        }

        /// <summary>Chip selected: null tag = "All", otherwise a backend filter id.</summary>
        private void FilterChip_Checked(object sender, RoutedEventArgs e)
        {
            if (sender is not RadioButton chip)
                return;

            _activeFilter = chip.Tag as string;
            // Re-run the query through the selected backend filter; chips are
            // only visible when there is a query to filter.
            var query = SearchBox.Text?.Trim();
            if (!string.IsNullOrEmpty(query))
                _ = RunSearchAsync(query, SaveToHistory: false);
        }

        private void ClearResults()
        {
            _allResults = new List<SearchResultItemView>();
            _activeFilter = null;
            _displayResults.Clear();
            FilterChips.Children.Clear();
            FilterChips.Visibility = Visibility.Collapsed;
            ResultsList.Visibility = Visibility.Collapsed;
        }

        private async Task RunSearchAsync(string query, bool SaveToHistory)
        {
            if (string.IsNullOrEmpty(query))
            {
                // Box emptied: drop stale results + chips, back to the prompt.
                ClearResults();
                ResultsPlaceholder.Text = "Type to search YouTube Music.";
                ResultsPlaceholder.Visibility = Visibility.Visible;
                return;
            }

            var generation = ++_searchGeneration;
            ResultsPlaceholder.Visibility = Visibility.Collapsed;
            ErrorText.Visibility = Visibility.Collapsed;
            LoadingRing.IsActive = true;
            LoadingRing.Visibility = Visibility.Visible;

            try
            {
                if (SaveToHistory)
                    SearchHistory.Remember(query);

                // M2 fix (search): the backend search endpoint page-counts with a small
                // limit and returns raw ytmusicapi groups; every group is a real typed
                // SearchResultGroup, never null. Passing a filter is optional — the same
                // query is searched under every chip, so running All first would cost a
                // duplicate round-trip. Fetch once with the currently selected filter and
                // let the chip row + ApplyFilter re-slice the same result set.
                var results = await App.ApiClient.SearchAsync(query, _activeFilter);

                if (generation != _searchGeneration)
                    return; // a newer search superseded this one

                if (results == null || results.Count == 0)
                {
                    ClearResults();
                    ResultsPlaceholder.Text = $"No results for \u201C{query}\u201D.";
                    ResultsPlaceholder.Visibility = Visibility.Visible;
                    return;
                }

                _allResults = results
                    .Select(r => new SearchResultItemView(r))
                    .ToList();
                BuildFilterChips();
                ApplyFilter();
            }
            catch (ApiRequestException ex) when (ex.StatusCode == 401)
            {
                ClearResults();
                ResultsPlaceholder.Text = "Sign in to search your library and YouTube Music.";
                ResultsPlaceholder.Visibility = Visibility.Visible;
            }
            catch (Exception ex)
            {
                ErrorText.Text = "Search failed: " + ex.Message;
                ErrorText.Visibility = Visibility.Visible;
            }
            finally
            {
                if (generation == _searchGeneration)
                {
                    LoadingRing.IsActive = false;
                    LoadingRing.Visibility = Visibility.Collapsed;
                }
            }
        }

        /// <summary>
        /// Fixed chip row (All + real YT Music search filters). Chips re-run the
        /// query through the backend filter — the same tabs the YT Music web app
        /// offers. The chip matching the active filter is pre-checked, so the
        /// row survives result refreshes (each search rebuilds the row).
        /// </summary>
        private void BuildFilterChips()
        {
            FilterChips.Children.Clear();
            FilterChips.Visibility = Visibility.Visible;

            var allChip = new RadioButton
            {
                Content = "All",
                GroupName = "SearchFilters",
                // App-level lookup: the style lives in App.xaml's merged dictionaries
                // (Themes/NavStyles.xaml). Page.Resources["…"] only searches the page's
                // own dictionary and throws "Cannot find a resource with the given key"
                // instead of falling back up the tree, which made every search fail.
                Style = (Style)Application.Current.Resources["FilterChipRadioButton"],
                IsChecked = string.IsNullOrEmpty(_activeFilter)
            };
            allChip.Checked += FilterChip_Checked;
            FilterChips.Children.Add(allChip);

            foreach (var (id, label) in SearchFilters.Known)
            {
                var chip = new RadioButton
                {
                    Content = label,
                    GroupName = "SearchFilters",
                    Style = (Style)Application.Current.Resources["FilterChipRadioButton"],
                    Tag = id,
                    IsChecked = id == _activeFilter
                };
                chip.Checked += FilterChip_Checked;
                FilterChips.Children.Add(chip);
            }
        }

        private void ApplyFilter()
        {
            _displayResults.Clear();
            foreach (var r in _allResults)
                _displayResults.Add(r);
            ResultsList.Visibility = _displayResults.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            if (_displayResults.Count == 0)
            {
                ResultsPlaceholder.Text = "No results.";
                ResultsPlaceholder.Visibility = Visibility.Visible;
            }
        }

        // ---------------- recent searches ----------------

        private void HistoryFlyout_Opened(object sender, object e)
        {
            RefreshHistoryList();
        }

        private void RefreshHistoryList()
        {
            var entries = SearchHistory.Entries.ToList();
            HistoryList.ItemsSource = entries;
            HistoryEmptyText.Visibility = entries.Count > 0 ? Visibility.Collapsed : Visibility.Visible;
            ClearHistoryButton.IsEnabled = entries.Count > 0;
        }

        private void HistoryItem_Click(object sender, RoutedEventArgs e)
        {
            if ((sender as FrameworkElement)?.DataContext is not string query || string.IsNullOrEmpty(query))
                return;

            HistoryFlyout.Hide();
            SearchBox.Text = query;           // raises TextChanged → debounced auto-search
            SearchBox.Focus(FocusState.Programmatic);
            SearchBox.Select(SearchBox.Text.Length, 0);
        }

        private void ClearHistoryButton_Click(object sender, RoutedEventArgs e)
        {
            SearchHistory.Clear();
            RefreshHistoryList();
        }

        private void RemoveHistoryItem_Click(object sender, RoutedEventArgs e)
        {
            if ((sender as FrameworkElement)?.DataContext is string query && !string.IsNullOrEmpty(query))
            {
                SearchHistory.Remove(query);
                RefreshHistoryList();
            }
        }

        internal void ResetForTest()
        {
            _activeFilter = null;
            SearchHistory.SetEntries(Array.Empty<string>());
            RefreshHistoryList();
            ClearResults();
        }
    }
}
