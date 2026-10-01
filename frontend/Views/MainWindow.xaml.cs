using System;
using System.Diagnostics;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using YtMusicClient.Services;

namespace YtMusicClient.Views
{
    public sealed partial class MainWindow : Window
    {
        private ApiClient _apiClient;

        public MainWindow()
        {
            InitializeComponent();

            // Extends content into the title bar; our glass chrome (AppTitleBar) becomes
            // the interactive title bar, with real caption buttons at the top-right.
            ExtendsContentIntoTitleBar = true;
            SetTitleBar(AppTitleBar);
            Title = "YouTube Music";
            AppWindow.Resize(new Windows.Graphics.SizeInt32(1200, 800));

            HomeTab.Checked += NavTab_Checked;
            SearchTab.Checked += NavTab_Checked;
            LibraryTab.Checked += NavTab_Checked;
            NowPlayingTab.Checked += NavTab_Checked;

            ContentFrame.Navigate(typeof(HomePage));
        }

        public async Task InitializeAsync(int port)
        {
            _apiClient = new ApiClient($"http://127.0.0.1:{port}");

            // ContentDialog needs a XamlRoot, which the window content only gets once loaded.
            for (int i = 0; Content is FrameworkElement root && root.XamlRoot == null && i < 100; i++)
                await Task.Delay(50);

            bool? isLoggedIn = await TryGetAuthStatusAsync();
            App.ShellViewModel.IsLoggedIn = isLoggedIn == true;
            if (isLoggedIn == null)
            {
                App.ShellViewModel.AuthStatusText = "Backend not reachable";
                await ShowMessageDialogAsync(
                    $"The backend is not responding at http://127.0.0.1:{port}. " +
                    "Check that Python and the backend requirements are installed, then restart the app.");
                return;
            }

            if (!isLoggedIn.Value)
            {
                App.ShellViewModel.AuthStatusText = "Not signed in";
                await ShowLoginDialogAsync();
            }
            else
            {
                App.ShellViewModel.AuthStatusText = "Signed in";
            }
        }

        private void NavTab_Checked(object sender, RoutedEventArgs e)
        {
            var tab = sender as RadioButton;
            if (tab == null || ContentFrame == null)
                return;

            var tag = tab.Tag as string;
            if (tag == "home")
                ContentFrame.Navigate(typeof(HomePage));
            else if (tag == "search")
                ContentFrame.Navigate(typeof(SearchPage));
            else if (tag == "library")
                ContentFrame.Navigate(typeof(LibraryPage));
            else if (tag == "nowplaying")
                ContentFrame.Navigate(typeof(NowPlayingPage));
        }

        private async Task<bool?> TryGetAuthStatusAsync()
        {
            // The backend writes its port file just before it starts listening; give it a moment.
            for (int attempt = 0; attempt < 5; attempt++)
            {
                try
                {
                    return await _apiClient.GetAuthStatusAsync();
                }
                catch (Exception)
                {
                    await Task.Delay(500);
                }
            }
            return null;
        }

        private async Task ShowLoginDialogAsync()
        {
            ContentDialog dialog = null;

            var signInButton = new Button { Content = "Sign In" };
            signInButton.Click += async (sender, args) =>
            {
                try
                {
                    var (url, code) = await _apiClient.LoginAsync();
                    Process.Start(new ProcessStartInfo { FileName = url, UseShellExecute = true });
                    await dialog.HideAsync();
                    await ShowMessageDialogAsync(
                        $"If the browser did not open, go to {url} and enter code: {code}");
                }
                catch (Exception ex)
                {
                    try { await dialog.HideAsync(); } catch (Exception) { }
                    await ShowMessageDialogAsync("Login failed: " + ex.Message);
                }
            };

            dialog = new ContentDialog
            {
                Title = "Sign in with Google",
                Content = new StackPanel
                {
                    Children =
                    {
                        new TextBlock { Text = "Please sign in to continue.", Margin = new Thickness(0, 0, 0, 10) },
                        signInButton
                    }
                },
                CloseButtonText = "Cancel",
                XamlRoot = Content.XamlRoot
            };
            await dialog.ShowAsync();
        }

        private async Task ShowMessageDialogAsync(string message)
        {
            var dialog = new ContentDialog
            {
                Content = message,
                CloseButtonText = "OK",
                XamlRoot = Content.XamlRoot
            };
            await dialog.ShowAsync();
        }
    }
}
