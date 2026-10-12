using System;
using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using YtMusicClient.Services;

namespace YtMusicClient.Views
{
    /// <summary>
    /// Now Playing: ambient artwork background, a 3-card carousel — current track
    /// center, previous/next smaller at the sides (click to jump; the right card
    /// previews the next song, per the mockup) — seek bar, like + autoplay
    /// actions, and a floating transport pill whose mini chip shows the playing
    /// track. (The Up Next rail this used to describe was removed from the page;
    /// the queue is represented by the side preview cards.) Binds to
    /// <see cref="PlayerState"/> and <see cref="QueueManager"/> via x:Bind for
    /// text; one PropertyChanged subscription each drives the imperative bits
    /// (artwork, carousel, seek bar, times). No polling timers.
    /// </summary>
    public sealed partial class NowPlayingPage : Page
    {
        public ViewModels.MainShellViewModel ViewModel { get; } = App.ShellViewModel;

        public PlayerState Player => App.PlayerState;
        public QueueManager Queue => App.Queue;

        // Last artwork painted, so a track change (not every state tick) drives
        // the cross-fade into the new ambient + card art.
        private string _lastArtUrl;

        public NowPlayingPage()
        {
            InitializeComponent();

            App.PlayerState.PropertyChanged += Player_PropertyChanged;
            App.Queue.PropertyChanged += Queue_PropertyChanged;
            App.Playback.PropertyChanged += Playback_PropertyChanged;
        }

        private void NowPlayingPage_OnLoaded(object sender, RoutedEventArgs e)
        {
            RefreshFromState(); // pages are cached (NavigationCacheMode=Enabled): catch up on load
            RefreshCarousel();  // side preview cards need this too: queue changes alone won't fire while hidden
            if (App.Window is MainWindow mainWindow)
                mainWindow.SetPlayerBarVisible(false); // this page IS the full player
        }

        private void NowPlayingPage_OnUnloaded(object sender, RoutedEventArgs e)
        {
            // PropertyChanged stays subscribed: the page is cached and re-shown,
            // and the handlers are cheap when nothing is playing.
            if (App.Window is MainWindow mainWindow)
                mainWindow.SetPlayerBarVisible(true);
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

        /// <summary>PlaybackService changes: art swap refresh for the center card + mini chip.</summary>
        private void Playback_PropertyChanged(object sender, PropertyChangedEventArgs e)
        {
            if (e.PropertyName == nameof(PlaybackService.CurrentArtworkUrl))
            {
                var queue = App.Window?.DispatcherQueue;
                if (queue == null || queue.HasThreadAccess)
                    Player_ArtworkChanged();
                else
                    _ = queue.TryEnqueue(Player_ArtworkChanged);
            }
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

        /// <summary>Artwork swaps: refresh the center card and the mini chip so the
        /// transport pill track art can update without waiting on another Track change.
        /// Mirrors the new CurrentArtworkUrl path (M2 playback polish).</summary>
        private void Player_ArtworkChanged()
        {
            var url = App.Playback.CurrentArtworkUrl;
            SetArt(CarouselCurrentArt, url);
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

                case nameof(PlayerState.Volume):
                    PageMuteGlyph.Glyph = Player.VolumePercent <= 0 ? "\uE74F" : "\uE767"; // muted : speaker
                    break;

                case nameof(PlayerState.Shuffle):
                case nameof(PlayerState.Repeat):
                    UpdatePlayModes();
                    break;
            }
        }

        /// <summary>
        /// Update the ambient background + the carousel cards from the current
        /// track. Called on Track change (and on load for cached pages).
        /// </summary>
        private void RefreshFromState()
        {
            var state = App.PlayerState;
            string url = state.Track?.ArtworkUrl;
            bool artChanged = !string.Equals(url, _lastArtUrl, StringComparison.Ordinal);
            _lastArtUrl = url;

            // Ambient background: the current track's own art, oversized + dimmed.
            SetImageSource(AmbientArt, url);
            AmbientArt.Visibility = !string.IsNullOrEmpty(url) ? Visibility.Visible : Visibility.Collapsed;
            AmbientOverlay.Visibility = AmbientArt.Visibility;

            // New track: ease the ambient wash and the card art in instead of
            // hard-swapping, so skipping tracks feels continuous.
            if (artChanged)
            {
                Motion.Fade(AmbientArt, 0, 0.3, 0.45);
                Motion.Fade(CarouselCurrentArt, 0.35, 1, 0.35);
            }

            // Center card: track title first (the prominent line), artist beneath it.
            SetArt(CarouselCurrentArt, url);
            CurrentTitle.Text = state.Track?.Title ?? "";
            CurrentArtist.Text = state.Track?.Artist ?? "";

            PageMuteGlyph.Glyph = state.VolumePercent <= 0 ? "\uE74F" : "\uE767";

            // Per-track/local state: re-sync so a cached page (or a track that
            // just changed) never shows the previous track's like or modes.
            UpdateLikeGlyph();
            UpdatePlayModes();

            // Side cards refresh on the next queue tick (Queue_PropertyChanged
            // → RefreshCarousel) so they always reflect the live queue.
            if (!state.HasTrack)
            {
                CarouselPrev.Visibility = Visibility.Collapsed;
                CarouselNext.Visibility = Visibility.Collapsed;
            }
        }

        /// <summary>
        /// Side preview cards: previous (left) and next (right) with their real
        /// artist/track labels inside the glass card — the right card is the
        /// "next song preview" the mockup shows.
        /// </summary>
        private void RefreshCarousel()
        {
            var prev = Queue.Previous;
            SetArt(CarouselPrevArt, prev?.ArtworkUrl);
            CarouselPrev.Visibility = prev != null ? Visibility.Visible : Visibility.Collapsed;
            if (prev != null)
            {
                CarouselPrevTitle.Text = prev.Title ?? "";
                CarouselPrevArtist.Text = prev.Artist ?? "";
            }

            var next = Queue.Upcoming.Count > 0 ? Queue.Upcoming[0] : null;
            SetArt(CarouselNextArt, next?.ArtworkUrl);
            CarouselNext.Visibility = next != null ? Visibility.Visible : Visibility.Collapsed;
            if (next != null)
            {
                CarouselNextTitle.Text = next.Title ?? "";
                CarouselNextArtist.Text = next.Artist ?? "";
            }
        }

        private static void SetImageSource(Image image, string url)
        {
            if (image == null)
                return;
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

        /// <summary>Art painted as a Border's ImageBrush background: the rounded
        /// corners clip the brush (a raw Image child would poke out of rounded
        /// corners). Falls back to the raised placeholder on bad/empty URLs.</summary>
        private static void SetArt(Border host, string url)
        {
            if (host == null)
                return;

            if (string.IsNullOrEmpty(url))
            {
                host.Background = (Brush)Application.Current.Resources["RaisedBrush"];
                return;
            }

            try
            {
                host.Background = new ImageBrush
                {
                    ImageSource = new BitmapImage(new Uri(url)),
                    Stretch = Stretch.UniformToFill
                };
            }
            catch (UriFormatException)
            {
                host.Background = (Brush)Application.Current.Resources["RaisedBrush"];
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

        private void PageMuteButton_Click(object sender, RoutedEventArgs e)
        {
            var volume = App.PlayerState.VolumePercent;
            App.PlayerState.VolumePercent = volume > 0 ? 0 : 80;
        }

        /// <summary>Like toggle: flips the local PlayerState.Liked only.</summary>
        /// <remarks>The backend like endpoint is not wired yet (flagged to the user);
        /// the heart icon reflects local state so the UI is honest about what it knows.</remarks>
        private void LikeButton_Click(object sender, RoutedEventArgs e)
        {
            Player.Liked = !Player.Liked;
            UpdateLikeGlyph();
        }

        /// <summary>Paint the heart from PlayerState.Liked. Re-run on track change and
        /// page reload so it can never display a stale track's like.</summary>
        private void UpdateLikeGlyph()
        {
            LikeGlyph.Foreground = Player.Liked
                ? (Brush)Application.Current.Resources["AccentBrush"]
                : (Brush)Application.Current.Resources["TextSecondaryBrush"];
            LikeGlyph.Glyph = Player.Liked ? "\uE736" : "\uE735"; // filled heart : outline heart
        }

        private void ShuffleButton_Click(object sender, RoutedEventArgs e)
        {
            Player.Shuffle = !Player.Shuffle;
            UpdatePlayModes();
        }

        /// <summary>Repeat cycles off → all → one, matching PlayerState.RepeatMode.</summary>
        private void RepeatButton_Click(object sender, RoutedEventArgs e)
        {
            Player.Repeat = Player.Repeat switch
            {
                RepeatMode.Off => RepeatMode.All,
                RepeatMode.All => RepeatMode.One,
                _ => RepeatMode.Off,
            };
            UpdatePlayModes();
        }

        /// <summary>Accent marks an active shuffle/repeat, per DESIGN_TOKENS (accent
        /// only for active/interactive states); the labels stay descriptive.</summary>
        private void UpdatePlayModes()
        {
            var accent = (Brush)Application.Current.Resources["AccentBrush"];
            var secondary = (Brush)Application.Current.Resources["TextSecondaryBrush"];

            ShuffleGlyph.Foreground = Player.Shuffle ? accent : secondary;

            RepeatGlyph.Foreground = Player.Repeat != RepeatMode.Off ? accent : secondary;
            RepeatGlyph.Glyph = Player.Repeat == RepeatMode.One ? "\uE8ED" : "\uE8EE"; // one : all

            ShuffleButton.SetValue(AutomationProperties.NameProperty,
                Player.Shuffle ? "Shuffle on" : "Shuffle off");
            RepeatButton.SetValue(AutomationProperties.NameProperty,
                "Repeat " + Player.Repeat.ToString().ToLowerInvariant());
        }

        private static string FormatTime(TimeSpan time)
        {
            if (time < TimeSpan.Zero) time = TimeSpan.Zero;
            return time.TotalHours >= 1 ? time.ToString(@"h\:mm\:ss") : time.ToString(@"m\:ss");
        }
    }
}
