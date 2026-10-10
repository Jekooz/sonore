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
    /// Library: the signed-in user's playlists, subscribed artists, saved albums,
    /// channel subscriptions and liked songs — all fetched live from their real
    /// YouTube Music account through the backend.
    /// </summary>
    public sealed partial class LibraryPage : Page
    {
        public ViewModels.MainShellViewModel ViewModel { get; } = App.ShellViewModel;

        private bool _subscribed;
        private bool _loadedOnce;

        public LibraryPage()
        {
            InitializeComponent();
            Loaded += LibraryPage_Loaded;
            Unloaded += LibraryPage_Unloaded;
        }

        private async void LibraryPage_Loaded(object sender, RoutedEventArgs e)
        {
            if (!_subscribed)
            {
                ViewModel.DataReady += ViewModel_DataReady;
                _subscribed = true;
            }
            await LoadAsync(force: false);
        }

        private void LibraryPage_Unloaded(object sender, RoutedEventArgs e)
        {
            if (_subscribed)
            {
                ViewModel.DataReady -= ViewModel_DataReady;
                _subscribed = false;
            }
        }

        private void ViewModel_DataReady(object sender, EventArgs e)
        {
            _ = DispatcherQueue.TryEnqueue(async () => await LoadAsync(force: true));
        }

        private async Task LoadAsync(bool force)
        {
            if (!ViewModel.IsLoggedIn)
            {
                SignedOutPanel.Visibility = Visibility.Visible;
                ContentScroll.Visibility = Visibility.Collapsed;
                return;
            }

            SignedOutPanel.Visibility = Visibility.Collapsed;
            if (_loadedOnce && !force)
                return;

            ContentScroll.Visibility = Visibility.Visible;
            SetBusy(true);
            ErrorText.Visibility = Visibility.Collapsed;

            try
            {
                var playlists = App.ApiClient.GetLibraryPlaylistsAsync();
                var artists = App.ApiClient.GetLibraryArtistsAsync();
                var albums = App.ApiClient.GetLibraryAlbumsAsync();
                var liked = App.ApiClient.GetLikedSongsAsync();
                var subs = App.ApiClient.GetLibrarySubscriptionsAsync();

                await Task.WhenAll(playlists, artists, albums, liked, subs);

                PlaylistsList.ItemsSource = (await playlists)
                    .Select(p => new PlaylistItemView(p)).ToList();
                ArtistsList.ItemsSource = (await artists)
                    .Select(a => new ArtistItemView(a)).ToList();
                AlbumsList.ItemsSource = (await albums)
                    .Select(a => new AlbumItemView(a)).ToList();
                LikedList.ItemsSource = (await liked)
                    .Select(t => new TrackItemView(t)).ToList();
                SubscriptionsList.ItemsSource = (await subs)
                    .Select(s => new ArtistItemView(s)).ToList();

                _loadedOnce = true;
            }
            catch (ApiRequestException ex) when (ex.StatusCode == 401)
            {
                ViewModel.IsLoggedIn = false;
                ViewModel.AuthStatusText = "Session expired";
                SignedOutPanel.Visibility = Visibility.Visible;
                ContentScroll.Visibility = Visibility.Collapsed;
            }
            catch (Exception ex)
            {
                ErrorText.Text = "Could not load your library: " + ex.Message;
                ErrorText.Visibility = Visibility.Visible;
            }
            finally
            {
                SetBusy(false);
            }
        }

        private void SetBusy(bool busy)
        {
            LoadingRing.IsActive = busy;
            LoadingRing.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        }

        private async void SignInButton_Click(object sender, RoutedEventArgs e)
        {
            if (App.Window is MainWindow mainWindow)
                await mainWindow.StartSignInAsync();
        }

        /// <summary>Liked-row click: start playback and jump to the Now Playing tab.
        /// The liked list is the queue, so Next walks it from the clicked track.</summary>
        private async void LikedTrack_Click(object sender, RoutedEventArgs e)
        {
            if ((sender as FrameworkElement)?.DataContext is not TrackItemView item)
                return;
            if (string.IsNullOrEmpty(item.VideoId))
                return;

            List<QueueTrack> queue = LikedList.ItemsSource is IEnumerable<TrackItemView> tracks
                ? tracks.Where(t => !string.IsNullOrEmpty(t.VideoId))
                    .Select(t => new QueueTrack(t.VideoId, t.Title, t.ArtistText, t.ThumbnailUrl))
                    .ToList()
                : new List<QueueTrack>();
            if (queue.Count == 0)
                queue.Add(new QueueTrack(item.VideoId, item.Title, item.ArtistText, item.ThumbnailUrl));

            await App.Playback.PlayAsync(queue, queue.FindIndex(t => t.VideoId == item.VideoId));
            if (App.Window is MainWindow mainWindow)
                mainWindow.ShowNowPlaying();
        }

        /// <summary>Playlist card click: open the playlist's real tracklist.</summary>
        private async void PlaylistCard_Click(object sender, RoutedEventArgs e)
        {
            if ((sender as FrameworkElement)?.DataContext is not PlaylistItemView item)
                return;

            await OpenCollectionAsync(null, item.PlaylistId, item.ThumbnailUrl);
        }

        /// <summary>Album card click (art included): open the album's real tracklist.</summary>
        private async void AlbumCard_Click(object sender, RoutedEventArgs e)
        {
            if ((sender as FrameworkElement)?.DataContext is not AlbumItemView item)
                return;

            await OpenCollectionAsync(item.BrowseId, null, item.ThumbnailUrl);
        }

        /// <summary>Artist / subscription card click: open the artist's real tracklist.</summary>
        private async void ArtistCard_Click(object sender, RoutedEventArgs e)
        {
            if ((sender as FrameworkElement)?.DataContext is not ArtistItemView item)
                return;

            await OpenCollectionAsync(item.BrowseId, null, item.ThumbnailUrl);
        }

        /// <summary>
        /// Resolve the card's collection through the backend, then open its
        /// tracklist page. A card that does not resolve (or that the backend
        /// refuses) stays a no-op rather than opening an empty page. Library
        /// cards used to carry no click handler at all, so they were inert.
        /// </summary>
        private async Task OpenCollectionAsync(string browseId, string playlistId, string fallbackArtUrl)
        {
            var detail = await CollectionQueue.ResolveAsync(browseId, playlistId);
            if (detail == null)
                return;

            if (App.Window is MainWindow mainWindow)
                mainWindow.ShowCollection(new CollectionRequest(detail, fallbackArtUrl));
        }

        private void ShowOnly(string section)
        {
            if (PlaylistsView == null)
                return; // XAML not fully initialized during parse

            PlaylistsView.Visibility = section == "playlists" ? Visibility.Visible : Visibility.Collapsed;
            ArtistsView.Visibility = section == "artists" ? Visibility.Visible : Visibility.Collapsed;
            AlbumsView.Visibility = section == "albums" ? Visibility.Visible : Visibility.Collapsed;
            LikedView.Visibility = section == "liked" ? Visibility.Visible : Visibility.Collapsed;
            SubscriptionsView.Visibility = section == "subscriptions" ? Visibility.Visible : Visibility.Collapsed;
        }

        private void LibraryTab_Playlists(object sender, RoutedEventArgs e) => ShowOnly("playlists");
        private void LibraryTab_Artists(object sender, RoutedEventArgs e) => ShowOnly("artists");
        private void LibraryTab_Albums(object sender, RoutedEventArgs e) => ShowOnly("albums");
        private void LibraryTab_Liked(object sender, RoutedEventArgs e) => ShowOnly("liked");
        private void LibraryTab_Subscriptions(object sender, RoutedEventArgs e) => ShowOnly("subscriptions");
    }
}
