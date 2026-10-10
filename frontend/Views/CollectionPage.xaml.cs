using System;
using System.Collections.Generic;
using System.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Navigation;
using YtMusicClient.Services;

namespace YtMusicClient.Views
{
    /// <summary>
    /// A collection page: the real tracklist of an album, playlist or artist.
    ///
    /// Reached by tapping a collection card on Home / Search / Library. The card
    /// already resolved the collection through the backend, so this page renders
    /// from the passed-in detail and never re-fetches. Clicking a row plays that
    /// track with the collection as the queue (so Next keeps walking it), and the
    /// floating button bottom-right plays the whole thing from the first track.
    /// </summary>
    public sealed partial class CollectionPage : Page
    {
        private CollectionRequest _request;
        private List<QueueTrack> _queue = new();

        public CollectionPage()
        {
            InitializeComponent();
        }

        protected override void OnNavigatedTo(NavigationEventArgs e)
        {
            base.OnNavigatedTo(e);
            _request = e.Parameter as CollectionRequest;
            Render();
        }

        private void Render()
        {
            var detail = _request?.Detail;
            if (detail == null)
            {
                ShowError("This collection could not be loaded.");
                return;
            }

            KindText.Text = KindLabel(detail.Kind);
            TitleText.Text = detail.Title;
            SubtitleText.Text = detail.Subtitle ?? "";
            SubtitleText.Visibility = string.IsNullOrEmpty(detail.Subtitle)
                ? Visibility.Collapsed
                : Visibility.Visible;

            // One filter, used for both the queue and the rows, so a row's Index
            // is exactly its index in the queue.
            var tracks = (detail.Tracks ?? new List<Track>())
                .Where(t => !string.IsNullOrEmpty(t.VideoId))
                .ToList();

            _queue = tracks
                .Select(t => new QueueTrack(
                    t.VideoId,
                    t.Title,
                    t.ArtistText,
                    Thumbnail.PickUrl(t.Thumbnails, 544) ?? _request.FallbackArtUrl))
                .ToList();

            CountText.Text = _queue.Count == 1 ? "1 song" : $"{_queue.Count} songs";

            string artUrl = _request.FallbackArtUrl;
            if (string.IsNullOrEmpty(artUrl))
            {
                HeaderArtHost.Visibility = Visibility.Collapsed;
            }
            else
            {
                HeaderArtHost.Visibility = Visibility.Visible;
                HeaderArt.ImageSource = new BitmapImage(new Uri(artUrl));
            }

            if (_queue.Count == 0)
            {
                ShowError("This collection has no playable tracks.");
                return;
            }

            TrackList.ItemsSource = tracks
                .Select((t, i) => new CollectionTrackView(t, i))
                .ToList();

            LoadingRing.IsActive = false;
            StatusPanel.Visibility = Visibility.Collapsed;
            TrackList.Visibility = Visibility.Visible;
            PlayAllButton.Visibility = Visibility.Visible;
        }

        private void ShowError(string message)
        {
            LoadingRing.IsActive = false;
            LoadingRing.Visibility = Visibility.Collapsed;
            ErrorText.Text = message;
            ErrorText.Visibility = Visibility.Visible;
            StatusPanel.Visibility = Visibility.Visible;
            TrackList.Visibility = Visibility.Collapsed;
            PlayAllButton.Visibility = Visibility.Collapsed;
        }

        /// <summary>Floating play button: play the whole collection from track 1.</summary>
        private async void PlayAllButton_Click(object sender, RoutedEventArgs e)
        {
            if (_queue.Count == 0)
                return;

            await App.Playback.PlayAsync(_queue, 0);
        }

        /// <summary>Row click: play that track, with the collection as the queue.</summary>
        private async void TrackRow_Click(object sender, RoutedEventArgs e)
        {
            if ((sender as FrameworkElement)?.DataContext is not CollectionTrackView row)
                return;
            if (row.Index < 0 || row.Index >= _queue.Count)
                return;

            await App.Playback.PlayAsync(_queue, row.Index);
        }

        private void BackButton_Click(object sender, RoutedEventArgs e)
        {
            if (Frame != null && Frame.CanGoBack)
                Frame.GoBack();
            else if (App.Window is MainWindow mainWindow)
                mainWindow.ShowNowPlaying();
        }

        private static string KindLabel(string kind) => kind switch
        {
            "album" => "Album",
            "playlist" => "Playlist",
            "artist" => "Artist",
            _ => "Collection",
        };
    }
}
