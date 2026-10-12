using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.CompilerServices;
using System.Text.Json;

namespace YtMusicClient.Services
{
    public enum ElementThemeSetting { Dark = 0, Light = 1, System = 2 }

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
        private bool _isFinished;
        private TimeSpan _position;
        private TimeSpan _duration;
        private double _bufferedFraction;
        private string _statusText = "";
        private bool _liked;
        private bool _shuffle;
        private RepeatMode _repeat = RepeatMode.Off;
        private bool _autoplayOn = true;
        private ElementThemeSetting _appTheme = ElementThemeSetting.Dark;
        private double _volume = 0.8;

        public ElementThemeSetting AppTheme
        {
            get => _appTheme;
            set
            {
                if (Set(ref _appTheme, value))
                {
                    Persist("AppTheme", (int)value);
                    ApplyTheme(value);
                }
            }
        }

        public static void ApplyTheme(ElementThemeSetting setting)
        {
            if (App.Window?.Content is Microsoft.UI.Xaml.FrameworkElement root)
            {
                root.RequestedTheme = setting switch
                {
                    ElementThemeSetting.Dark => Microsoft.UI.Xaml.ElementTheme.Dark,
                    ElementThemeSetting.Light => Microsoft.UI.Xaml.ElementTheme.Light,
                    _ => Microsoft.UI.Xaml.ElementTheme.Default,
                };
            }
        }

        // Settings live in %LOCALAPPDATA%\YtMusicClient\settings.json — the same
        // folder as the audio cache. ApplicationData.Current throws
        // InvalidOperationException for unpackaged apps (WindowsAppSDK #1721;
        // verified in ytmusic_crash.log: PlayerState..ctor → OnLaunched on the
        // UI thread), so a plain JSON file is the one storage that works here.
        private static readonly string SettingsPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "YtMusicClient", "settings.json");
        private static readonly object SettingsGate = new object();
        private static Dictionary<string, double> _settings;

        private static Dictionary<string, double> GetSettings()
        {
            lock (SettingsGate)
            {
                if (_settings != null)
                    return _settings;

                Dictionary<string, double> loaded = null;
                bool corrupt = false;
                try
                {
                    if (File.Exists(SettingsPath))
                        loaded = JsonSerializer.Deserialize<Dictionary<string, double>>(
                            File.ReadAllText(SettingsPath));
                }
                catch
                {
                    corrupt = true; // hand-edited or truncated file → defaults
                }
                _settings = loaded ?? new Dictionary<string, double>();
                if (corrupt)
                    PlaybackLog.Write("settings.json unreadable — falling back to defaults");
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
                    // Like is per-track (the backend like endpoint is not wired
                    // yet), so a new track must start unliked — otherwise the
                    // heart stays lit from whatever played before.
                    Liked = false;
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
        public bool IsBusy { get => _isBusy; set { if (Set(ref _isBusy, value)) { Raise(nameof(CanToggle)); Raise(nameof(CanSeek)); } } }

        /// <summary>The track reached its end with nothing to advance to. Mirrors
        /// PlaybackService's own flag: a finished track can neither resume nor seek.</summary>
        public bool IsFinished { get => _isFinished; set { if (Set(ref _isFinished, value)) Raise(nameof(CanSeek)); } }

        public string PlayGlyph => IsPlaying ? "\uE769" : "\uE768"; // pause : play
        public bool CanToggle => HasTrack && !IsBusy;

        /// <summary>
        /// True only when a seek would actually take effect. PlaybackService.Seek ignores
        /// seeks while nothing is loaded (resolving or buffering) and once the track has
        /// finished, but both seek bars were gated on HasTrack alone — so during
        /// "Resolving stream…" they accepted a drag that silently did nothing and then
        /// snapped back on the next tick. CanToggle is the play button's equivalent gate.
        /// </summary>
        public bool CanSeek => HasTrack && !IsBusy && !IsFinished;

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

        public bool Shuffle { get => _shuffle; set { if (Set(ref _shuffle, value)) Persist("Shuffle", value ? 1 : 0); } }
        public RepeatMode Repeat { get => _repeat; set { if (Set(ref _repeat, value)) Persist("RepeatMode", (int)value); } }
        public bool AutoplayOn { get => _autoplayOn; set { if (Set(ref _autoplayOn, value)) Persist("AutoplayOn", value ? 1 : 0); } }

        public double Volume
        {
            get => _volume;
            set
            {
                if (Set(ref _volume, Math.Clamp(value, 0, 1)))
                {
                    Persist("Volume", _volume);
                    Raise(nameof(VolumePercent));
                }
            }
        }

        /// <summary>The volume as the slider sees it (0-100).</summary>
        public double VolumePercent
        {
            get => Volume * 100;
            set => Volume = value / 100.0;
        }

        public PlayerState()
        {
            try
            {
                _volume = Math.Clamp(ReadDouble("Volume", 0.8), 0, 1);
                _shuffle = ReadDouble("Shuffle", 0) != 0;
                _autoplayOn = ReadDouble("AutoplayOn", 1) != 0;
                _repeat = (RepeatMode)Math.Clamp((int)ReadDouble("RepeatMode", 0), 0, 2);
                _appTheme = (ElementThemeSetting)Math.Clamp((int)ReadDouble("AppTheme", 0), 0, 2);
            }
            catch
            {
                // Unreadable settings must never block startup — keep defaults.
            }
        }

        // ---------------- plumbing ----------------

        private static void Persist(string key, double value)
        {
            try
            {
                lock (SettingsGate)
                {
                    GetSettings()[key] = value;
                    Directory.CreateDirectory(Path.GetDirectoryName(SettingsPath));
                    File.WriteAllText(SettingsPath, JsonSerializer.Serialize(GetSettings()));
                }
            }
            catch { /* persisting must never break playback */ }
        }

        private static double ReadDouble(string key, double fallback)
        {
            return GetSettings().TryGetValue(key, out double value) ? value : fallback;
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
