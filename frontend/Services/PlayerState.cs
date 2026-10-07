using System;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using Windows.Storage;

namespace YtMusicClient.Services
{
    public enum RepeatMode { Off, All, One }

    /// <summary>
    /// The single bindable playback truth: track, transport state, position,
    /// volume, shuffle/repeat/like/autoplay. The player bar and Now Playing
    /// bind ONLY to this instance (no per-page polling timers), so icons can
    /// never disagree — there is one source. PlaybackService writes it,
    /// pages read it. Volume/shuffle/repeat/autoplay persist across runs.
    /// </summary>
    public sealed class PlayerState : INotifyPropertyChanged
    {
        private QueueTrack _track;
        private bool _isPlaying;
        private bool _isBusy;
        private TimeSpan _position;
        private TimeSpan _duration;
        private double _bufferedFraction;
        private string _statusText = "";
        private bool _liked;
        private bool _shuffle;
        private RepeatMode _repeat = RepeatMode.Off;
        private bool _autoplayOn = true;
        private double _volume = 0.8;

        // Lazy-init settings — ApplicationData.Current.LocalSettings must be
        // accessed from the UI thread in WinUI3, but this type is constructed
        // during App type init / OnLaunched before the dispatcher is pumping.
        // Defer reads until first use (lazy), and swallow any failure so the
        // app can still run with defaults.
        private static ApplicationDataContainer _settings;
        private static ApplicationDataContainer Settings
        {
            get
            {
                if (_settings != null) return _settings;
                try
                {
                    _settings = ApplicationData.Current.LocalSettings;
                }
                catch
                {
                    // If ApplicationData isn't ready yet (e.g. during early
                    // initialization), just leave it null — reads will fall
                    // back to defaults and the app keeps running.
                    _settings = null;
                }
                return _settings;
            }
        }

        public event PropertyChangedEventHandler PropertyChanged;

        public QueueTrack Track
        {
            get => _track;
            set
            {
                if (Set(ref _track, value))
                {
                    Raise(nameof(HasTrack));
                    Raise(nameof(TrackTitle));
                    Raise(nameof(TrackArtist));
                    Raise(nameof(PanelVisibility));
                    Raise(nameof(EmptyStateVisibility));
                    Raise(nameof(ArtistVisibility));
                }
            }
        }

        public bool HasTrack => Track != null;
        public string TrackTitle => Track?.Title ?? "Nothing playing";
        public string TrackArtist => Track?.Artist ?? "";

        // Typed visibilities for x:Bind (no converters in this app).
        public Microsoft.UI.Xaml.Visibility PanelVisibility => HasTrack ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;
        public Microsoft.UI.Xaml.Visibility EmptyStateVisibility => HasTrack ? Microsoft.UI.Xaml.Visibility.Collapsed : Microsoft.UI.Xaml.Visibility.Visible;
        public Microsoft.UI.Xaml.Visibility ArtistVisibility => string.IsNullOrEmpty(TrackArtist) ? Microsoft.UI.Xaml.Visibility.Collapsed : Microsoft.UI.Xaml.Visibility.Visible;

        public bool IsPlaying { get => _isPlaying; set { if (Set(ref _isPlaying, value)) Raise(nameof(PlayGlyph)); } }
        public bool IsBusy { get => _isBusy; set { if (Set(ref _isBusy, value)) Raise(nameof(CanToggle)); } }
        public string PlayGlyph => IsPlaying ? "\uE769" : "\uE768"; // pause : play
        public bool CanToggle => HasTrack && !IsBusy;

        /// <summary>Position — raised from the engine's 4 Hz tick, not a per-page timer.</summary>
        public TimeSpan Position { get => _position; set => Set(ref _position, value); }
        public TimeSpan Duration { get => _duration; set => Set(ref _duration, value); }
        public double BufferedFraction { get => _bufferedFraction; set => Set(ref _bufferedFraction, value); }
        public string StatusText
        {
            get => _statusText;
            set
            {
                if (Set(ref _statusText, value))
                    Raise(nameof(StatusVisibility));
            }
        }

        public Microsoft.UI.Xaml.Visibility StatusVisibility => string.IsNullOrEmpty(StatusText) ? Microsoft.UI.Xaml.Visibility.Collapsed : Microsoft.UI.Xaml.Visibility.Visible;
        public bool Liked { get => _liked; set => Set(ref _liked, value); }

        public bool Shuffle { get => _shuffle; set { if (Set(ref _shuffle, value)) Persist("Shuffle", value); } }
        public RepeatMode Repeat { get => _repeat; set { if (Set(ref _repeat, value)) Persist("RepeatMode", (int)value); } }
        public bool AutoplayOn { get => _autoplayOn; set { if (Set(ref _autoplayOn, value)) Persist("AutoplayOn", value); } }

        public double Volume
        {
            get => _volume;
            set
            {
                if (Set(ref _volume, Math.Clamp(value, 0, 1)))
                {
                    Persist("VolumeSliderPercent", _volume);
                    Raise(nameof(VolumePercent));
                }
            }
        }

        /// <summary>The volume as the slider sees it (0-100). Same settings key as the
        /// old MainShellViewModel value, so an existing install keeps its level.</summary>
        public double VolumePercent
        {
            get => Volume * 100;
            set => Volume = value / 100.0;
        }

        public PlayerState()
        {
            // Defer settings reads — they happen lazily on first access to
            // ApplicationData.Current.LocalSettings, which avoids the crash
            // that occurred when this constructor ran before the UI thread
            // dispatcher was ready.
            try
            {
                var settings = Settings;
                if (settings != null)
                {
                    _volume = ReadDouble(settings, "VolumeSliderPercent", 0.8);
                    _shuffle = ReadDouble(settings, "Shuffle", 0) != 0;
                    _autoplayOn = ReadDouble(settings, "AutoplayOn", 1) != 0;
                    _repeat = (RepeatMode)Math.Clamp((int)ReadDouble(settings, "RepeatMode", 0), 0, 2);
                }
            }
            catch
            {
                // If settings access fails for any reason, keep defaults.
            }
        }

        // ---------------- plumbing ----------------

        private static void Persist(string key, object value)
        {
            try
            {
                var settings = Settings;
                if (settings != null)
                    settings.Values[key] = value;
            }
            catch { /* persisting must never break playback */ }
        }

        private static double ReadDouble(ApplicationDataContainer settings, string key, double fallback)
        {
            try
            {
                object stored = settings.Values[key];
                if (stored is double d) return d;
                if (stored is long l) return l; // XAML setters box as long
                if (stored is int i) return i;
            }
            catch { }
            return fallback;
        }

        private bool Set<T>(ref T field, T value, [CallerMemberName] string name = null)
        {
            if (Equals(field, value))
                return false;
            field = value;
            Raise(name);
            return true;
        }

        private void Raise(string name) =>
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}
