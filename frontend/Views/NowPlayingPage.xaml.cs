using System;
using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using YtMusicClient.Services;

namespace YtMusicClient.Views
{
    /// <summary>
    /// Now Playing: ambient artwork background, 3D-style fan carousel of the
    /// previous/current/next tracks, big title/artist, action icons (like +
    /// queue), the Up Next panel, an autoplay toggle, and a floating transport
    /// pill. Binds to <see cref="PlayerState"/> and <see cref="QueueManager"/>
    /// via x:Bind for text; one PropertyChanged subscription each drives the
    /// imperative bits (artwork, carousel, seek bar, times). No polling timers.
    /// </summary>
    public sealed partial class NowPlayingPage : Page
    {
        public ViewModels.MainShellViewModel ViewModel { get; } = App.ShellViewModel;

        public PlayerState Player => App.PlayerState;
        public QueueManager Queue => App.Queue;

        public NowPlayingPage()
        {
            InitializeComponent();

            App.PlayerState.PropertyChanged += Player_PropertyChanged;
            App.Queue.PropertyChanged += Queue_PropertyChanged;
            Loaded += NowPlayingPage_Loaded;
            Unloaded += NowPlayingPage_Unloaded;
        }

        private void NowPlayingPage_Loaded(object sender, RoutedEventArgs e)
        {
            RefreshFromState(); // pages are cached (NavigationCacheMode=Enabled): catch up on load
        }

        private void NowPlayingPage_Unloaded(object sender, RoutedEventArgs e)
        {
            // PropertyChanged stays subscribed: the page is cached and re-shown,
            // and the handlers are cheap when nothing is playing.
        }

        /// <summary>PlayerState changes: track/artwork, seek bar, times.</summary>
        private void Player_PropertyChanged(object sender, PropertyChangedEventArgs e)
        {
            var queue = App.Window?.DispatcherQueue;
            if (queue == null || queue.HasThreadAccess)
                ApplyPlayerChange(e.PropertyName);
            else
                _ = queue.TryEnqueue(() => ApplyPlayerChange(e.PropertyName));
        }

        /// <summary>QueueManager changes: carousel (prev/current/next) redraw.</summary>
        private void Queue_PropertyChanged(object sender, PropertyChangedEventArgs e)
        {
            if (e.PropertyName is nameof(QueueManager.Current)
                or nameof(QueueManager.Previous)
                or nameof(QueueManager.Upcoming)
                or nameof(QueueManager.HasUpcoming))
            {
                var queue = App.Window?.DispatcherQueue;
                if (queue == null || queue.HasThreadAccess)
                    RefreshCarousel();
                else
                    _ = queue.TryEnqueue(RefreshCarousel);
            }
        }

        private void ApplyPlayerChange(string propertyName)
        {
            switch (propertyName)
            {
                case nameof(PlayerState.Track):
                    RefreshFromState();
                    break;

                case nameof(PlayerState.Position):
                case nameof(PlayerState.Duration):
                case nameof(PlayerState.BufferedFraction):
                    if (!SeekBar.IsDragging)
                    {
                        SeekBar.Update(Player.Duration.TotalSeconds, Player.Position.TotalSeconds, Player.BufferedFraction);
                        PositionText.Text = FormatTime(Player.Position);
                    }
                    DurationText.Text = Player.Duration > TimeSpan.Zero ? FormatTime(Player.Duration) : "–:––";
                    break;
            }
        }

        /// <summary>
        /// Update the ambient background + the carousel artwork from the current
        /// track (and its prev/next neighbours). Called on Track change and on
        /// queue changes.
        /// </summary>
        private void RefreshFromState()
        {
            var state = App.PlayerState;
            string url = state.Track?.ArtworkUrl;

            // Ambient background: the current track's own art, dimmed.
            SetImageSource(AmbientArt, url);
            AmbientArt.Visibility = !string.IsNullOrEmpty(url) ? Visibility.Visible : Visibility.Collapsed;
            AmbientOverlay.Visibility = AmbientArt.Visibility;

            // Carousel: current artwork is the big center card.
            SetImageSource(CarouselCurrentImage, url);
            CarouselCurrentImage.Visibility = state.HasTrack ? Visibility.Visible : Visibility.Collapsed;

            // Carousel neighbours refresh on the next queue tick (Queue_PropertyChanged
            // → RefreshCarousel) so they always reflect the live queue.
            if (!state.HasTrack)
            {
                CarouselPrev.Visibility = Visibility.Collapsed;
                CarouselNext.Visibility = Visibility.Collapsed;
            }
        }

        private void RefreshCarousel()
        {
            // Previous card: the track before current in the queue.
            var prev = Queue.Previous;
            SetImageSource(CarouselPrevImage, prev?.ArtworkUrl);
            CarouselPrev.Visibility = prev != null ? Visibility.Visible : Visibility.Collapsed;

            // Next card: the first upcoming track.
            var next = Queue.Upcoming.Count > 0 ? Queue.Upcoming[0] : null;
            SetImageSource(CarouselNextImage, next?.ArtworkUrl);
            CarouselNext.Visibility = next != null ? Visibility.Visible : Visibility.Collapsed;
        }

        private static void SetImageSource(Image image, string url)
        {
            if (string.IsNullOrEmpty(url))
            {
                image.Source = null;
                return;
            }

            try
            {
                image.Source = new BitmapImage(new Uri(url));
            }
            catch (UriFormatException)
            {
                image.Source = null; // bad URL: quiet placeholder, don't crash
            }
        }

        private void SeekBar_PreviewChanged(object sender, double seconds)
        {
            PositionText.Text = FormatTime(TimeSpan.FromSeconds(seconds));
        }

        private void SeekBar_SeekRequested(object sender, double seconds)
        {
            App.Playback.Seek(TimeSpan.FromSeconds(seconds));
        }

        private void PlayPause_Click(object sender, RoutedEventArgs e)
            => App.Playback.TogglePlayPause();

        private void PrevButton_Click(object sender, RoutedEventArgs e)
            => App.Playback.PreviousByHistory?.Invoke();

        private void NextButton_Click(object sender, RoutedEventArgs e)
            => App.Playback.Next?.Invoke();

        /// <summary>Like toggle: flips the local PlayerState.Liked only.</summary>
        /// <remarks>The backend like endpoint is not wired yet (flagged to the user);
        /// the heart icon reflects local state so the UI is honest about what it knows.</remarks>
        private void LikeButton_Click(object sender, RoutedEventArgs e)
        {
            Player.Liked = !Player.Liked;
            LikeGlyph.Foreground = Player.Liked
                ? (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["AccentBrush"]
                : (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextSecondaryBrush"];
            LikeGlyph.Glyph = Player.Liked ? "\uE736" : "\uE735"; // filled heart : outline heart
        }

        /// <summary>Queue button: scroll the Up Next panel into view.</summary>
        private void QueueButton_Click(object sender, RoutedEventArgs e)
        {
            if (UpNextPanel.Visibility == Visibility.Visible)
            {
                UpNextPanel.StartBringIntoView();
            }
        }

        /// <summary>Up Next item click: start playback from that track in the current queue.</summary>
        private async void UpNext_Click(object sender, RoutedEventArgs e)
        {
            if ((sender as FrameworkElement)?.DataContext is not QueueTrack track)
                return;
            if (string.IsNullOrEmpty(track.VideoId))
                return;

            // The visible Up Next list is the queue context; play from this track.
            var queue = new System.Collections.Generic.List<QueueTrack>(Queue.Upcoming.Count + 1);
            queue.Add(Player.Track ?? track);
            foreach (var t in Queue.Upcoming)
                queue.Add(t);

            int idx = queue.FindIndex(t => t.VideoId == track.VideoId);
            if (idx < 0)
                idx = 0;

            await App.Playback.PlayAsync(queue, idx);
            if (App.Window is MainWindow mainWindow)
                mainWindow.ShowNowPlaying();
        }

        private static string FormatTime(TimeSpan time)
        {
            if (time < TimeSpan.Zero) time = TimeSpan.Zero;
            return time.TotalHours >= 1 ? time.ToString(@"h\:mm\:ss") : time.ToString(@"m\:ss");
        }
    }
}
