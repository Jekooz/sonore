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
    }
}
