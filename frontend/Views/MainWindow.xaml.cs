using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using YtMusicClient.Services;
using YtMusicClient.ViewModels;

namespace YtMusicClient.Views
{
    public sealed partial class MainWindow : Window
    {
        private ApiClient _apiClient;

        private static string FormatTime(TimeSpan time)
        {
            if (time < TimeSpan.Zero) time = TimeSpan.Zero;
            return time.TotalHours >= 1 ? time.ToString(@"h\:mm\:ss") : time.ToString(@"m\:ss");
        }

        // 400 ms poll for position/duration — they change without state transitions.


        /// <summary>Shared shell state, source for the title-bar account chip.</summary>
        public MainShellViewModel ViewModel => App.ShellViewModel;

        /// <summary>Bind targets for the player bar: one shared state, no polling timers.</summary>
        public Services.PlayerState Player => App.PlayerState;
        public Services.QueueManager Queue => App.Queue;

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

            ViewModel.PropertyChanged += ShellViewModel_PropertyChanged;
            UpdateAccountChrome();

            // Player bar: x:Bind to Player/Queue for text and glyphs; one
            // PropertyChanged subscription drives the imperative bits
            // (seek bar, times, artwork, mute glyph). No polling timer.
            App.PlayerState.PropertyChanged += Player_PropertyChanged;
            UpdateBarArtwork();

            // Shell hooks the SMTC controller uses.
            App.Playback.PreviousByHistory = () => App.Playback.Previous(PlayTrackAsync);
            App.Playback.Next = () => App.Playback.PlayNext();

            // System Media Transport Controls: media keys, lock screen, volume flyout.
            _smtc = new SmtcController(App.Playback, this);

            ContentFrame.Navigate(typeof(HomePage));
        }

        private readonly SmtcController _smtc;

        private async Task PlayTrackAsync(string videoId, string title, string artist, string artworkUrl)
            => await App.Playback.PlayAsync(videoId, title, artist, artworkUrl);

        /// <summary>
        /// Imperative bar updates that x:Bind cannot express: the seek bar,
        /// time labels, artwork fill, and the mute glyph — all driven by
        /// PlayerState changes (position arrives at the engine's 4 Hz tick).
        /// </summary>
        private void Player_PropertyChanged(object sender, PropertyChangedEventArgs e)
        {
            _ = DispatcherQueue.TryEnqueue(() =>
            {
                switch (e.PropertyName)
                {
                    case nameof(Services.PlayerState.Position):
                    case nameof(Services.PlayerState.Duration):
                    case nameof(Services.PlayerState.BufferedFraction):
                        var state = App.PlayerState;
                        if (!BarSeekBar.IsDragging)
                        {
                            BarSeekBar.Update(state.Duration.TotalSeconds, state.Position.TotalSeconds, state.BufferedFraction);
                            BarPositionText.Text = FormatTime(state.Position);
                        }
                        BarDurationText.Text = state.Duration > TimeSpan.Zero ? FormatTime(state.Duration) : "–:––";
                        break;

                    case nameof(Services.PlayerState.Track):
                        UpdateBarArtwork();
                        break;

                    case nameof(Services.PlayerState.Volume):
                        BarMuteGlyph.Text = App.PlayerState.VolumePercent <= 0 ? "\uE74F" : "\uE767"; // muted : speaker
                        break;
                }
            });
        }

        private void UpdateBarArtwork()
        {
            var state = App.PlayerState;
            bool has = state.HasTrack;
            string url = state.Track?.ArtworkUrl;

            if (has && !string.Equals(_barArtworkUrl, url, StringComparison.Ordinal))
            {
                _barArtworkUrl = url;
                try
                {
                    BarArt.Background = string.IsNullOrEmpty(url)
                        ? (Brush)Application.Current.Resources["RaisedBrush"]
                        : new ImageBrush { ImageSource = new BitmapImage(new Uri(url)), Stretch = Stretch.UniformToFill };
                }
                catch (UriFormatException)
                {
                    BarArt.Background = (Brush)Application.Current.Resources["RaisedBrush"];
                }
            }
            else if (!has)
            {
                _barArtworkUrl = null;
                BarArt.Background = (Brush)Application.Current.Resources["RaisedBrush"];
            }
        }

        private string _barArtworkUrl;

        private void BarSeekBar_PreviewChanged(object sender, double seconds)
        {
            BarPositionText.Text = FormatTime(TimeSpan.FromSeconds(seconds));
        }

        private void BarSeekBar_SeekRequested(object sender, double seconds)
        {
            // BufferedSeekBar.IsDragging is already false on release; the next
            // timer tick resumes driving the bar from real playback.
            App.Playback.Seek(TimeSpan.FromSeconds(seconds));
        }

        private void PlayerBarExpand_Click(object sender, RoutedEventArgs e)
            => ShowNowPlaying();

        private void BarPlayButton_Click(object sender, RoutedEventArgs e)
            => App.Playback.TogglePlayPause();

        private void BarPrevButton_Click(object sender, RoutedEventArgs e)
            => App.Playback.PreviousByHistory?.Invoke();

        private void BarNextButton_Click(object sender, RoutedEventArgs e)
            => App.Playback.Next?.Invoke();

        private void BarMuteButton_Click(object sender, RoutedEventArgs e)
        {
            bool muted = App.PlayerState.VolumePercent > 0;
            App.PlayerState.VolumePercent = muted ? 0 : _volumeBeforeMute;
        }

        private double _volumeBeforeMute = 80;

        private void BarVolumeSlider_ValueChanged(object sender, object e)
        {
            // The slider binds TwoWay to Player.VolumePercent; this handler only
            // remembers the last non-zero level for the mute button.
            if (BarVolumeSlider.Value > 0)
                _volumeBeforeMute = BarVolumeSlider.Value;
        }

        /// <summary>
        /// Keep the title bar in sync with sign-in state: the account chip
        /// (photo + name, with a sign-out menu) replaces the wordmark once
        /// the account is known.
        /// </summary>
        private void ShellViewModel_PropertyChanged(object sender, PropertyChangedEventArgs e)
        {
            if (e.PropertyName is nameof(MainShellViewModel.IsLoggedIn)
                or nameof(MainShellViewModel.AccountName)
                or nameof(MainShellViewModel.AccountPhotoUrl))
            {
                _ = DispatcherQueue.TryEnqueue(UpdateAccountChrome);
            }
        }

        private void UpdateAccountChrome()
        {
            bool signedIn = ViewModel.IsLoggedIn;
            AccountChip.Visibility = signedIn ? Visibility.Visible : Visibility.Collapsed;
            AppTitleText.Visibility = signedIn ? Visibility.Collapsed : Visibility.Visible;

            bool hasPhoto = !string.IsNullOrEmpty(ViewModel.AccountPhotoUrl);
            AccountPhoto.Visibility = hasPhoto ? Visibility.Visible : Visibility.Collapsed;
            PhotoFallback.Visibility = hasPhoto ? Visibility.Collapsed : Visibility.Visible;
            // Imperative Fill: a string→ImageSource x:Bind crashes on null/empty
            // (XamlBindingHelper.ConvertValue throws E_INVALIDARG).
            AccountPhoto.Fill = hasPhoto
                ? new ImageBrush { ImageSource = new BitmapImage(new Uri(ViewModel.AccountPhotoUrl)) }
                : null;

            var name = ViewModel.AccountName ?? "";
            AccountInitial.Text = string.IsNullOrEmpty(name) ? "" : name.Trim()[0].ToString().ToUpperInvariant();
        }

        /// <summary>
        /// Sign out for real: clears the stored session on the backend, then
        /// resets the shell state so every page drops back to the sign-in
        /// prompt. The Home tab shows that prompt.
        /// </summary>
        private async void SignOut_Click(object sender, RoutedEventArgs e)
        {
            if (_apiClient == null)
                return;

            try
            {
                await _apiClient.SignOutAsync();
            }
            catch (Exception ex)
            {
                await ShowMessageDialogAsync("Could not sign out: " + ex.Message);
                return;
            }

            ViewModel.IsLoggedIn = false;
            ViewModel.AccountName = "";
            ViewModel.AccountPhotoUrl = null; // empty string would crash the ImageSource x:Bind
            ViewModel.AuthStatusText = "Signed out";
            // Cached pages re-evaluate their signed-in state on DataReady.
            ViewModel.RaiseDataReady();

            HomeTab.IsChecked = true;
        }

        public async Task InitializeAsync(int port, string sidecarError = null)
        {
            // ContentDialog needs a XamlRoot, which the window content only gets once loaded.
            for (int i = 0; Content is FrameworkElement root && root.XamlRoot == null && i < 100; i++)
                await Task.Delay(50);

            if (sidecarError != null)
            {
                App.ShellViewModel.AuthStatusText = "Backend not reachable";
                await ShowMessageDialogAsync(
                    "The backend failed to start:" + Environment.NewLine + sidecarError +
                    Environment.NewLine + Environment.NewLine +
                    "Check that Python and the backend requirements are installed, then restart the app.");
                return;
            }

            _apiClient = new ApiClient($"http://127.0.0.1:{port}");
            App.ApiClient = _apiClient;

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
                    App.ShellViewModel.AccountPhotoUrl = string.IsNullOrEmpty(account.AccountPhotoUrl) ? null : account.AccountPhotoUrl;
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

        /// <summary>
        /// Switch to the Now Playing tab. Called when playback starts so the
        /// transport is immediately visible; setting IsChecked raises Checked,
        /// which is what performs the navigation.
        /// </summary>
        public void ShowNowPlaying()
        {
            NowPlayingTab.IsChecked = true;
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
                App.ShellViewModel.AccountPhotoUrl = string.IsNullOrEmpty(account.AccountPhotoUrl) ? null : account.AccountPhotoUrl;
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
            // The backend publishes its port only after it is accepting connections,
            // but the first request can still race process/thread startup. Give it a
            // generous window so a slow cold start is not reported as "not reachable".
            for (int attempt = 0; attempt < 30; attempt++)
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
