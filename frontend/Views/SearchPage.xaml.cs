using System;
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
    /// </summary>
    public sealed partial class SearchPage : Page
    {
        private int _searchGeneration;

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
                    ResultsList.ItemsSource = null;
                    ResultsPlaceholder.Text = $"No results for \u201C{query}\u201D.";
                    ResultsPlaceholder.Visibility = Visibility.Visible;
                    return;
                }

                ResultsList.ItemsSource = results
                    .Select(r => new SearchResultItemView(r))
                    .ToList();
            }
            catch (ApiRequestException ex) when (ex.StatusCode == 401)
            {
                ResultsPlaceholder.Text = "Sign in to search your library and YouTube Music.";
                ResultsPlaceholder.Visibility = Visibility.Visible;
                ResultsList.ItemsSource = null;
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
