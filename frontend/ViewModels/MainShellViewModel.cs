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
        private string accountPhotoUrl = "";

        /// <summary>
        /// Raised after sign-in completes (or account details refresh) so cached
        /// pages can immediately load personalized data.
        /// </summary>
        public event Action DataReady;

        public void RaiseDataReady() => DataReady?.Invoke(this, EventArgs.Empty);
    }
}
