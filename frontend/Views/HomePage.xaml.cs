using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System;
using System.Linq;
using System.Threading.Tasks;
using YtMusicClient.Services;

namespace YtMusicClient.Views
{
    /// <summary>
    /// Home: account greeting + "Recommended for you" rows from get_home(),
    /// with an inline sign-in prompt while signed out. All data comes from
    /// the real YouTube Music account via the backend — no mock content.
    /// </summary>
    public sealed partial class HomePage : Page
    {
        public ViewModels.MainShellViewModel ViewModel { get; } = App.ShellViewModel;

        private bool _subscribed;
        private bool _loadedOnce;

        public HomePage()
        {
            InitializeComponent();
            Loaded += HomePage_Loaded;
            Unloaded += HomePage_Unloaded;
        }

        private void HomePage_Loaded(object sender, RoutedEventArgs e)
        {
            if (!_subscribed)
            {
                ViewModel.DataReady += ViewModel_DataReady;
                _subscribed = true;
            }
            _ = LoadAsync(force: false);
        }

        private void HomePage_Unloaded(object sender, RoutedEventArgs e)
        {
            if (_subscribed)
            {
                ViewModel.DataReady -= ViewModel_DataReady;
                _subscribed = false;
            }
        }

        private void ViewModel_DataReady(object sender, EventArgs e)
        {
            _ = DispatcherQueue.TryEnqueue(() => LoadAsync(force: true));
        }

        private async Task LoadAsync(bool force)
        {
            if (!ViewModel.IsLoggedIn)
            {
                SignedOutPanel.Visibility = Visibility.Visible;
                ContentScroll.Visibility = Visibility.Collapsed;
                return;
            }

            SignedOutPanel.Visibility = Visibility.Collapsed;
            if (_loadedOnce && !force)
                return;

            ContentScroll.Visibility = Visibility.Visible;
            LoadingRing.IsActive = true;
            LoadingRing.Visibility = Visibility.Visible;
            ErrorText.Visibility = Visibility.Collapsed;

            try
            {
                var rows = await App.ApiClient.GetHomeAsync();
                HomeRows.ItemsSource = rows
                    .Where(r => r.Contents != null && r.Contents.Count > 0)
                    .Select(r => new HomeRowView(r))
                    .ToList();
                _loadedOnce = true;
                if (rows.Count == 0)
                {
                    ErrorText.Text = "No suggestions available for your account yet.";
                    ErrorText.Visibility = Visibility.Visible;
                }
            }
            catch (ApiRequestException ex) when (ex.StatusCode == 401)
            {
                ViewModel.IsLoggedIn = false;
                ViewModel.AuthStatusText = "Session expired";
                SignedOutPanel.Visibility = Visibility.Visible;
                ContentScroll.Visibility = Visibility.Collapsed;
            }
            catch (Exception ex)
            {
                ErrorText.Text = "Could not load your recommendations: " + ex.Message;
                ErrorText.Visibility = Visibility.Visible;
            }
            finally
            {
                LoadingRing.IsActive = false;
                LoadingRing.Visibility = Visibility.Collapsed;
            }
        }

        private async void SignInButton_Click(object sender, RoutedEventArgs e)
        {
            if (App.Window is MainWindow mainWindow)
                await mainWindow.StartSignInAsync();
        }
    }
}
