using Microsoft.UI.Xaml.Controls;

namespace YtMusicClient.Views
{
    public sealed partial class SearchPage : Page
    {
        public SearchPage()
        {
            InitializeComponent();
        }

        private void SearchBox_KeyDown(object sender, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs e)
        {
            // Wired in the search milestone; keeps the box the real focus target.
        }
    }
}
