using Microsoft.UI.Xaml.Controls;

namespace YtMusicClient.Views
{
    public sealed partial class HomePage : Page
    {
        public ViewModels.MainShellViewModel ViewModel { get; } = App.ShellViewModel;

        public HomePage()
        {
            InitializeComponent();
        }
    }
}
