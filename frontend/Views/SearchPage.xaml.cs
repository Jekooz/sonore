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
    /// Search across YouTube Music (songs, albums, artists, playlists) via the
    /// backend /search endpoint. Typeahead: as the user types, a 300 ms debounce
    /// fires a search and the results update in place (virtualized ListView).
    /// Results can be filtered by their real backend category
    /// (Songs, Videos, Albums, …) via the chip row.
    /// </summary>
    public sealed partial class SearchPage : Page
    {
        private int _searchGeneration;
        private List<SearchResultItemView> _allResults = new();
        private string _activeCategory;
        private CancellationTokenSource _debounceCts;

        /// <summary>The currently displayed (filtered) results — bound to the ListView.</summary>
        public ObservableCollection<SearchResultItemView> _displayResults = new();

        public SearchPage()
        {
            InitializeComponent();
        }

        private void SearchBox_KeyDown(object sender, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs e)
        {
            if (e.Key == Windows.System.VirtualKey.Enter)
            {
                _ = RunSearchAsync();
                e.Handled = true;
            }
        }

        /// <summary>
        /// Typeahead: each keystroke cancels any in-flight debounce and starts a new
        /// 300 ms timer. When the timer fires, the current text is searched (unless
        /// a newer keystroke already superseded it).
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

            await RunSearchAsync();
        }

        /// <summary>
        /// Result click: song/video results carry a videoId and start playback;
        /// album/playlist/artist results need detail pages (later milestone).
        /// The visible (filtered) results are the queue, so Next walks them.
        /// </summary>
        private async void Result_Click(object sender, RoutedEventArgs e)
        {
            if ((sender as FrameworkElement)?.DataContext is not SearchResultItemView item)
                return;
            if (string.IsNullOrEmpty(item.VideoId))
                return;

            List<QueueTrack> queue = ResultsList.ItemsSource is IEnumerable<SearchResultItemView> visible
                ? visible.Where(r => !string.IsNullOrEmpty(r.VideoId))
                    .Select(r => new QueueTrack(r.VideoId, r.Title, r.Artist, r.ThumbnailUrl))
                    .ToList()
                : new List<QueueTrack>();
            if (queue.Count == 0)
                queue.Add(new QueueTrack(item.VideoId, item.Title, item.Artist, item.ThumbnailUrl));

            await App.Playback.PlayAsync(queue, queue.FindIndex(t => t.VideoId == item.VideoId));
            if (App.Window is MainWindow mainWindow)
                mainWindow.ShowNowPlaying();
        }

        /// <summary>Chip selected: null tag = "All", otherwise the category name.</summary>
        private void FilterChip_Checked(object sender, RoutedEventArgs e)
        {
            if (sender is not RadioButton chip)
                return;

            _activeCategory = chip.Tag as string;
            ApplyFilter();
        }

        private void ApplyFilter()
        {
            _displayResults.Clear();
            foreach (var r in string.IsNullOrEmpty(_activeCategory)
                ? _allResults
                : _allResults.Where(r => r.Category == _activeCategory))
                _displayResults.Add(r);
            ResultsList.Visibility = _displayResults.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        }

        /// <summary>
        /// Build the chip row from the distinct categories the backend
        /// actually returned, in the order they first appear.
        /// </summary>
        private void BuildFilterChips(List<string> categories)
        {
            FilterChips.Children.Clear();

            if (categories.Count == 0)
            {
                FilterChips.Visibility = Visibility.Collapsed;
                return;
            }

            FilterChips.Visibility = Visibility.Visible;

            var allChip = new RadioButton
            {
                Content = "All",
                GroupName = "SearchFilters",
                Style = (Style)Resources["FilterChipRadioButton"],
                IsChecked = true
            };
            allChip.Checked += FilterChip_Checked;
            FilterChips.Children.Add(allChip);

            foreach (var category in categories)
            {
                var chip = new RadioButton
                {
                    Content = category,
                    GroupName = "SearchFilters",
                    Style = (Style)Resources["FilterChipRadioButton"],
                    Tag = category
                };
                chip.Checked += FilterChip_Checked;
                FilterChips.Children.Add(chip);
            }
        }

        private void ClearResults()
        {
            _allResults = new List<SearchResultItemView>();
            _activeCategory = null;
            _displayResults.Clear();
            FilterChips.Children.Clear();
            FilterChips.Visibility = Visibility.Collapsed;
            ResultsList.Visibility = Visibility.Collapsed;
        }

        private async Task RunSearchAsync()
        {
            var query = SearchBox.Text?.Trim();
            if (string.IsNullOrEmpty(query))
                return;

            var generation = ++_searchGeneration;
            ResultsPlaceholder.Visibility = Visibility.Collapsed;
            ErrorText.Visibility = Visibility.Collapsed;
            LoadingRing.IsActive = true;
            LoadingRing.Visibility = Visibility.Visible;

            try
            {
                var results = await App.ApiClient.SearchAsync(query);

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
                _activeCategory = null;
                BuildFilterChips(_allResults
                    .Select(r => r.Category)
                    .Where(c => !string.IsNullOrEmpty(c))
                    .Distinct()
                    .ToList());
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
    }
}
