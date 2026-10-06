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
        private string accountPhotoUrl; // null, never "": an empty string cannot convert to ImageSource in x:Bind and crashes the app (0xC000027B)

        /// <summary>
        /// Raised after sign-in completes (or account details refresh) so cached
        /// pages can immediately load personalized data.
        /// </summary>
        public event EventHandler DataReady;

        public void RaiseDataReady() => DataReady?.Invoke(this, EventArgs.Empty);
    }
}
