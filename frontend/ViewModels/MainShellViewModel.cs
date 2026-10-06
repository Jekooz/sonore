using System;
using CommunityToolkit.Mvvm.ComponentModel;

namespace YtMusicClient.ViewModels
{
    public partial class MainShellViewModel : ObservableObject
    {
        [ObservableProperty]
        private bool isLoggedIn;

        [ObservableProperty]
        private string greeting = "Good evening";

        [ObservableProperty]
        private string authStatusText = "Checking sign-in…";

        [ObservableProperty]
        private string accountName = "";

        [ObservableProperty]
        private string accountPhotoUrl;

        // Volume as the user sees it (0-100 slider). Persisted so the level and
        // mute state survive restarts; PlaybackService applies the perceptual curve.
        private double _volumeSliderPercent = 80;
        public double VolumeSliderPercent
        {
            get => _volumeSliderPercent;
            set
            {
                double clamped = Math.Clamp(value, 0, 100);
                if (SetProperty(ref _volumeSliderPercent, clamped))
                    PersistVolume(clamped);
            }
        }

        public MainShellViewModel()
        {
            try
            {
                object stored = Windows.Storage.ApplicationData.Current.LocalSettings.Values["VolumeSliderPercent"];
                if (stored is double d) _volumeSliderPercent = Math.Clamp(d, 0, 100);
                else if (stored is long l) _volumeSliderPercent = Math.Clamp(l, 0, 100); // XAML setters box as long
            }
            catch
            {
                // First run or settings unavailable: keep the default.
            }
        }

        private static void PersistVolume(double value)
        {
            try
            {
                Windows.Storage.ApplicationData.Current.LocalSettings.Values["VolumeSliderPercent"] = value;
            }
            catch
            {
                // Persisting must never break playback.
            }
        } // null, never "": an empty string cannot convert to ImageSource in x:Bind and crashes the app (0xC000027B)

        /// <summary>
        /// Raised after sign-in completes (or account details refresh) so cached
        /// pages can immediately load personalized data.
        /// </summary>
        public event EventHandler DataReady;

        public void RaiseDataReady() => DataReady?.Invoke(this, EventArgs.Empty);
    }
}
