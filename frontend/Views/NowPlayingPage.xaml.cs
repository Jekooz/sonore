using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Dispatching;
using YtMusicClient.Services;

namespace YtMusicClient.Views
{
    /// <summary>
    /// Now Playing: centered artwork, metadata and transport for the track held by
    /// <see cref="App.Playback"/>. The persistent player bar (MainWindow) mirrors
    /// the same state; this page adds the full-size artwork and bigger transport.
    /// A 400 ms timer polls position/duration (they change without a state
    /// transition); the seek bar suspends its updates while the user drags.
    /// </summary>
    public sealed partial class NowPlayingPage : Page
    {
        public ViewModels.MainShellViewModel ViewModel { get; } = App.ShellViewModel;

        private readonly DispatcherTimer _timer;
        private string _boundArtworkUrl;

        public NowPlayingPage()
        {
            InitializeComponent();

            _timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(400) };
            _timer.Tick += Timer_Tick;

            Loaded += NowPlayingPage_Loaded;
            Unloaded += NowPlayingPage_Unloaded;
        }

        private void NowPlayingPage_Loaded(object sender, RoutedEventArgs e)
        {
            App.Playback.StateChanged += Playback_StateChanged;
            RefreshUi();
            _timer.Start();
        }

        private void NowPlayingPage_Unloaded(object sender, RoutedEventArgs e)
        {
            App.Playback.StateChanged -= Playback_StateChanged;
            _timer.Stop();
        }

        private void Playback_StateChanged(object sender, EventArgs e)
        {
            RefreshUi();
        }

        private void RefreshUi()
        {
            var playback = App.Playback;

            EmptyState.Visibility = playback.HasTrack ? Visibility.Collapsed : Visibility.Visible;
            NowPlayingPanel.Visibility = playback.HasTrack ? Visibility.Visible : Visibility.Collapsed;
            if (!playback.HasTrack)
                return;

            TitleText.Text = playback.Title;
            ArtistText.Text = playback.Artist;
            ArtistText.Visibility = string.IsNullOrWhiteSpace(playback.Artist)
                ? Visibility.Collapsed
                : Visibility.Visible;

            if (!string.Equals(_boundArtworkUrl, playback.ArtworkUrl, StringComparison.Ordinal))
            {
                _boundArtworkUrl = playback.ArtworkUrl;
                try
                {
                    ArtworkImage.Source = string.IsNullOrEmpty(playback.ArtworkUrl)
                        ? null
                        : new BitmapImage(new Uri(playback.ArtworkUrl));
                }
                catch (UriFormatException)
                {
                    ArtworkImage.Source = null; // bad URL: show the quiet placeholder, don't crash
                }
            }

            PlayPauseButton.IsEnabled = !playback.IsBusy;
            NextButton.IsEnabled = playback.HasNext;

            UpdateTimeDisplay();
            PlayPauseGlyph.Text = playback.IsPlaying ? "\uE769" : "\uE768"; // pause : play
        }

        private void Timer_Tick(object sender, object e)
        {
            if (App.Playback.HasTrack)
                UpdateTimeDisplay();
        }

        private void UpdateTimeDisplay()
        {
            var playback = App.Playback;
            var duration = playback.Duration;
            var position = playback.Position;

            // Quiet status line only for user-readable failures ("Playback failed: …").
            StatusText.Text = playback.StatusText;
            StatusText.Visibility = string.IsNullOrEmpty(playback.StatusText)
                ? Visibility.Collapsed
                : Visibility.Visible;

            DurationText.Text = duration > TimeSpan.Zero ? FormatTime(duration) : "–:––";
            if (!SeekBar.IsDragging)
            {
                SeekBar.Update(duration.TotalSeconds, position.TotalSeconds, playback.BufferedFraction);
                PositionText.Text = FormatTime(position);
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
