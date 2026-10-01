using Microsoft.UI.Xaml.Controls;

namespace YtMusicClient.Views
{
    /// <summary>
    /// Now Playing shell. Real playback (yt-dlp stream URLs + NAudio output +
    /// queue carousel) is the playback milestone; this page currently reflects
    /// sign-in state only.
    /// </summary>
    public sealed partial class NowPlayingPage : Page
    {
        public ViewModels.MainShellViewModel ViewModel { get; } = App.ShellViewModel;

        public NowPlayingPage()
        {
            InitializeComponent();
        }
    }
}
