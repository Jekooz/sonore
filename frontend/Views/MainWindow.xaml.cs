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
            App.ApiClient = _apiClient;

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
                await RunSignInFlowAsync();
            }
            else
            {
                await LoadSignedInStateAsync();
            }
        }

        /// <summary>
        /// Full in-app sign-in: opens the embedded Google sign-in window, captures
        /// cookies, hands them to the backend, and shows the result. The user never
        /// leaves the app and never copies a code.
        /// </summary>
        private async Task RunSignInFlowAsync()
        {
            var signInWindow = new SignInWindow();
            signInWindow.CookiesCaptured += async (sender, cookies) =>
            {
                if (cookies == null || cookies.Count == 0)
                    return;

                try
                {
                    var account = await _apiClient.SendCookiesAsync(cookies);
                    App.ShellViewModel.IsLoggedIn = true;
                    App.ShellViewModel.AuthStatusText = "Signed in";
                    App.ShellViewModel.AccountName = account.AccountName;
                    App.ShellViewModel.AccountPhotoUrl = account.AccountPhotoUrl;
                    App.ShellViewModel.RaiseDataReady();
                }
                catch (Exception ex)
                {
                    App.ShellViewModel.AuthStatusText = "Sign-in failed";
                    await ShowMessageDialogAsync(
                        "Google sign-in could not be completed: " + ex.Message +
                        "\n\nYou can try again from the Home tab.");
                }
            };

            bool signedIn = await signInWindow.ShowAndWaitAsync();
            if (!signedIn && !App.ShellViewModel.IsLoggedIn)
            {
                App.ShellViewModel.AuthStatusText = "Not signed in";
            }
        }

        /// <summary>Re-runs sign-in (Home tab button / sign-out flow).</summary>
        public async Task StartSignInAsync()
        {
            if (_apiClient == null)
                return;
            await RunSignInFlowAsync();
        }

        private async Task LoadSignedInStateAsync()
        {
            try
            {
                var account = await _apiClient.GetAccountAsync();
                App.ShellViewModel.AccountName = account.AccountName;
                App.ShellViewModel.AccountPhotoUrl = account.AccountPhotoUrl;
                App.ShellViewModel.AuthStatusText = "Signed in";
            }
            catch (ApiRequestException ex) when (ex.StatusCode == 401)
            {
                // Stored session expired — offer sign-in again.
                App.ShellViewModel.AuthStatusText = "Session expired";
                await RunSignInFlowAsync();
                return;
            }
            catch (Exception)
            {
                App.ShellViewModel.AuthStatusText = "Signed in (offline details)";
            }

            App.ShellViewModel.IsLoggedIn = true;
            App.ShellViewModel.RaiseDataReady();
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
                    var status = await _apiClient.GetAuthStatusAsync();
                    return status.LoggedIn;
                }
                catch (Exception)
                {
                    await Task.Delay(500);
                }
            }
            return null;
        }

        public async Task ShowMessageDialogAsync(string message)
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
