using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using YtMusicClient.Services;

namespace YtMusicClient.Views
{
    /// <summary>
    /// Search across YouTube Music (songs, albums, artists, playlists) via the
    /// backend /search endpoint. Debounced so typing feels instant.
    /// Results can be filtered by their real backend category
    /// (Songs, Videos, Albums, …) via the chip row.
    /// </summary>
    public sealed partial class SearchPage : Page
    {
        private int _searchGeneration;
        private List<SearchResultItemView> _allResults = new();
        private string _activeCategory;

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
        /// Result click: song/video results carry a videoId and start playback;
        /// album/playlist/artist results need detail pages (later milestone).
        /// </summary>
        private async void Result_Click(object sender, RoutedEventArgs e)
        {
            if ((sender as FrameworkElement)?.DataContext is not SearchResultItemView item)
                return;
            if (string.IsNullOrEmpty(item.VideoId))
                return;

            await App.Playback.PlayAsync(item.VideoId, item.Title, item.Artist, item.ThumbnailUrl);
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
            ResultsList.ItemsSource = string.IsNullOrEmpty(_activeCategory)
                ? _allResults
                : _allResults.Where(r => r.Category == _activeCategory).ToList();
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
            FilterChips.Children.Clear();
            FilterChips.Visibility = Visibility.Collapsed;
            ResultsList.ItemsSource = null;
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
