using System;
using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using YtMusicClient.Services;

namespace YtMusicClient.Views
{
    /// <summary>
    /// Now Playing: centered artwork, metadata and transport. Binds only to
    /// <see cref="PlayerState"/> (the shared state) via x:Bind for text and
    /// glyphs; one PropertyChanged subscription drives the imperative bits
    /// (artwork, seek bar, times). No polling timer — position arrives at the
    /// engine's 4 Hz tick through the shared state, exactly like the player bar.
    /// </summary>
    public sealed partial class NowPlayingPage : Page
    {
        public ViewModels.MainShellViewModel ViewModel { get; } = App.ShellViewModel;

        public PlayerState Player => App.PlayerState;
        public QueueManager Queue => App.Queue;

        private string _boundArtworkUrl;

        public NowPlayingPage()
        {
            InitializeComponent();
            App.PlayerState.PropertyChanged += Player_PropertyChanged;
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
            // and the handler is cheap when nothing is playing.
        }

        /// <summary>
        /// Imperative updates x:Bind cannot express: artwork fill, the seek
        /// bar, and the time labels. Same dispatch pattern as the player bar.
        /// </summary>
        private void Player_PropertyChanged(object sender, PropertyChangedEventArgs e)
        {
            var queue = App.Window?.DispatcherQueue;
            if (queue == null || queue.HasThreadAccess)
                ApplyChange(e.PropertyName);
            else
                _ = queue.TryEnqueue(() => ApplyChange(e.PropertyName));
        }

        private void ApplyChange(string propertyName)
        {
            var state = App.PlayerState;

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
                        SeekBar.Update(state.Duration.TotalSeconds, state.Position.TotalSeconds, state.BufferedFraction);
                        PositionText.Text = FormatTime(state.Position);
                    }
                    DurationText.Text = state.Duration > TimeSpan.Zero ? FormatTime(state.Duration) : "–:––";
                    break;
            }
        }

        private void RefreshFromState()
        {
            var state = App.PlayerState;

            if (!state.HasTrack)
            {
                ArtworkImage.Source = null;
                _boundArtworkUrl = null;
                return;
            }

            string url = state.Track?.ArtworkUrl;
            if (!string.Equals(_boundArtworkUrl, url, StringComparison.Ordinal))
            {
                _boundArtworkUrl = url;
                try
                {
                    ArtworkImage.Source = string.IsNullOrEmpty(url)
                        ? null
                        : new BitmapImage(new Uri(url));
                }
                catch (UriFormatException)
                {
                    ArtworkImage.Source = null; // bad URL: show the quiet placeholder, don't crash
                }
            }

            var duration = state.Duration;
            SeekBar.Update(duration.TotalSeconds, state.Position.TotalSeconds, state.BufferedFraction);
            DurationText.Text = duration > TimeSpan.Zero ? FormatTime(duration) : "–:––";
            PositionText.Text = FormatTime(state.Position);
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
        {
            App.Playback.TogglePlayPause();
        }

        private void PrevButton_Click(object sender, RoutedEventArgs e)
        {
            App.Playback.PreviousByHistory?.Invoke();
        }

        private void NextButton_Click(object sender, RoutedEventArgs e)
        {
            App.Playback.Next?.Invoke();
        }

        private static string FormatTime(TimeSpan time)
        {
            if (time < TimeSpan.Zero) time = TimeSpan.Zero;
            return time.TotalHours >= 1 ? time.ToString(@"h\:mm\:ss") : time.ToString(@"m\:ss");
        }
    }
}
