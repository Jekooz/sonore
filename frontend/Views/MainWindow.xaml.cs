using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
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
            // Tapping the tab you are already on has to work too: after opening a
            // collection sub-page the tab stays checked, so Checked never fires
            // again and that sub-page would otherwise be a dead end.
            HomeTab.Tapped += NavTab_Tapped;
            SearchTab.Tapped += NavTab_Tapped;
            LibraryTab.Tapped += NavTab_Tapped;
            NowPlayingTab.Tapped += NavTab_Tapped;

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
                        BarMuteGlyph.Glyph = App.PlayerState.VolumePercent <= 0 ? "\uE74F" : "\uE767"; // muted : speaker
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
        /// Keyboard shortcuts: Space = toggle play/pause, Left/Right = seek ±5s
        /// (clamped to [0, Duration]), Up/Down = volume ±5%. Skipped when the
        /// user is typing in a TextBox, dragging a Slider, or pressing a button —
        /// those elements own keyboard focus and their own accelerators/shortcuts.
        /// </summary>
        private bool CanAcceptKeyboardShortcut()
        {
            var focused = FocusManager.GetFocusedElement();
            if (focused == null)
                return true;

            // TextBox — user is typing text.
            if (focused is TextBox)
                return false;

            // Slider — user is scrubbing volume.
            if (focused is Slider)
                return false;

            // ButtonBase subtypes own their clicks.
            if (focused is Microsoft.UI.Xaml.Controls.Primitives.ButtonBase)
                return false;

            return true;
        }

        private void ToggleAccel_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
        {
            if (!CanAcceptKeyboardShortcut())
            {
                args.Handled = false;
                return;
            }

            App.Playback.TogglePlayPause();
            args.Handled = true;
        }

        private void SeekBackAccel_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
        {
            if (!CanAcceptKeyboardShortcut())
            {
                args.Handled = false;
                return;
            }

            var state = App.PlayerState;
            var pos = state.Position - TimeSpan.FromSeconds(5);
            App.Playback.Seek(pos < TimeSpan.Zero ? TimeSpan.Zero : pos);
            args.Handled = true;
        }

        private void SeekForwardAccel_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
        {
            if (!CanAcceptKeyboardShortcut())
            {
                args.Handled = false;
                return;
            }

            var state = App.PlayerState;
            var pos = state.Position + TimeSpan.FromSeconds(5);
            App.Playback.Seek(pos > state.Duration ? state.Duration : pos);
            args.Handled = true;
        }

        private void VolumeUpAccel_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
        {
            if (!CanAcceptKeyboardShortcut())
            {
                args.Handled = false;
                return;
            }

            var vol = App.PlayerState.VolumePercent;
            App.PlayerState.VolumePercent = Math.Min(100, vol + 5);
            args.Handled = true;
        }

        private void VolumeDownAccel_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
        {
            if (!CanAcceptKeyboardShortcut())
            {
                args.Handled = false;
                return;
            }

            var vol = App.PlayerState.VolumePercent;
            App.PlayerState.VolumePercent = Math.Max(0, vol - 5);
            args.Handled = true;
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

            var name = ViewModel.AccountName ?? "";

            if (signedIn && !string.IsNullOrEmpty(name))
                AccountChip.SetValue(AutomationProperties.NameProperty, "Account: " + name);
            else
                AccountChip.SetValue(AutomationProperties.NameProperty, "Account");

            bool hasPhoto = !string.IsNullOrEmpty(ViewModel.AccountPhotoUrl);
            AccountPhoto.Visibility = hasPhoto ? Visibility.Visible : Visibility.Collapsed;
            PhotoFallback.Visibility = hasPhoto ? Visibility.Collapsed : Visibility.Visible;
            // Imperative Fill: a string→ImageSource x:Bind crashes on null/empty
            // (XamlBindingHelper.ConvertValue throws E_INVALIDARG).
            AccountPhoto.Fill = hasPhoto
                ? new ImageBrush { ImageSource = new BitmapImage(new Uri(ViewModel.AccountPhotoUrl)) }
                : null;

            // Trim first, then index: a whitespace-only name would otherwise
            // index an empty string and throw IndexOutOfRange out of the
            // PropertyChanged handler.
            var trimmed = name.Trim();
            AccountInitial.Text = trimmed.Length == 0 ? "" : trimmed[0].ToString().ToUpperInvariant();
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
        /// Browser-based sign-in: the backend opens music.youtube.com in the
        /// user's DEFAULT browser; the paired extension hands the cookies back;
        /// this overlay mirrors /auth/browser/status until it settles. The user
        /// never copies a code; no embedded browser exists anymore.
        /// </summary>
        private async Task RunSignInFlowAsync()
        {
            BrowserAuthStatus status;
            try
            {
                status = await _apiClient.StartBrowserSignInAsync();
            }
            catch (Exception ex)
            {
                App.ShellViewModel.AuthStatusText = "Sign-in failed";
                await ShowMessageDialogAsync(
                    "Could not start the browser sign-in: " + ex.Message +
                    "\n\nMake sure the backend is running, then try again from the Home tab.");
                return;
            }

            ShowSignInOverlay(status);

            // Poll /auth/browser/status every 2 s (matching the backend's poll
            // interval) until the state leaves waiting/idle.
            try
            {
                while (true)
                {
                    await Task.Delay(2000);
                    status = await _apiClient.GetBrowserSignInStatusAsync();

                    UpdateSignInOverlay(status);

                    if (status.State is not "waiting" and not "idle")
                        break;
                }
            }
            catch (Exception)
            {
                status = new BrowserAuthStatus { State = "failed", Error = "Lost contact with the backend." };
            }
            finally
            {
                HideSignInOverlay();
            }

            if (status.State == "success")
            {
                await LoadSignedInStateAsync();
            }
            else if (status.State == "failed" || status.State == "timeout")
            {
                App.ShellViewModel.AuthStatusText = "Not signed in";
                // Point at the extension folder here: the sign-in card's
                // "Open the helper extension folder" button is collapsed by
                // HideSignInOverlay before this dialog is shown, so the path is
                // the only route the user actually has.
                await ShowMessageDialogAsync(
                    "Sign-in did not complete: " + (status.Error ?? status.State) +
                    "\n\nThis needs the helper extension loaded in the browser that just opened. " +
                    "Load it unpacked (chrome://extensions -> Developer mode) from:\n" +
                    (FindExtensionFolder() ?? "the browser-extension folder in the repo root") +
                    "\n\nThen try again from the Home tab.");
            }
            else // cancelled by the user
            {
                App.ShellViewModel.AuthStatusText = "Not signed in";
            }
        }

        // Guards the overlay's fade-out: a newer show/cancel bumps this so a
        // stale Completed callback cannot collapse the overlay the user reopened.
        private int _overlayAnimToken;

        private void ShowSignInOverlay(BrowserAuthStatus status)
        {
            SignInRing.IsActive = true;
            SignInHeadline.Text = string.IsNullOrEmpty(status.Browser) || status.Browser == "default browser"
                ? "Waiting for you to sign in in your browser…"
                : $"Waiting for you to sign in in {status.Browser}…";
            // Was "this app picks it up automatically", which is not true: the
            // cookies only arrive when the user clicks the helper extension's
            // toolbar button. Telling them otherwise leaves them waiting for a
            // hand-off that never starts (the 3-minute timeout then fires).
            SignInDetail.Text = "music.youtube.com should have opened in your default browser. " +
                "Sign in there, then click the YT Music Client Helper icon in that browser's toolbar.";
            _overlayAnimToken++;
            BrowserSignInOverlay.Visibility = Visibility.Visible;
            Motion.Fade(BrowserSignInOverlay, 0, 1, 0.22);
        }

        private void UpdateSignInOverlay(BrowserAuthStatus status)
        {
            if (status.State == "waiting")
                return; // headline already set at start

            if (status.State == "failed")
            {
                SignInRing.IsActive = false;
                SignInHeadline.Text = "Sign-in problem";
                SignInDetail.Text = status.Error ?? "The helper extension could not deliver the cookies.";
                // The extension step is the fix for the only expected failure mode.
                OpenExtensionFolderButton.Visibility = Visibility.Visible;
            }
        }

        private void HideSignInOverlay()
        {
            SignInRing.IsActive = false;
            OpenExtensionFolderButton.Visibility = Visibility.Collapsed;

            int token = ++_overlayAnimToken;
            Motion.FadeOut(BrowserSignInOverlay, 0.16, () =>
            {
                if (token == _overlayAnimToken)
                    BrowserSignInOverlay.Visibility = Visibility.Collapsed;
            });
        }

        private void CancelSignIn_Click(object sender, RoutedEventArgs e)
        {
            _ = CancelSignInAsync();
        }

        private async Task CancelSignInAsync()
        {
            try
            {
                await _apiClient.CancelBrowserSignInAsync();
            }
            catch
            {
                // Overlay close must not depend on the backend answering.
            }
            HideSignInOverlay();
            App.ShellViewModel.AuthStatusText = "Not signed in";
        }

        /// <summary>
        /// One-time helper: reveal the shipped extension folder so the user can
        /// load it unpacked (chrome://extensions -> Developer mode -> Load
        /// unpacked). Nothing is published to a web store.
        /// </summary>
        private void OpenExtensionFolder_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                var dir = FindExtensionFolder();
                if (dir != null)
                    Process.Start(new ProcessStartInfo { FileName = dir, UseShellExecute = true });
            }
            catch
            {
                // Opening Explorer is best-effort; the README documents the path.
            }
        }

        private static string FindExtensionFolder()
        {
            var dir = new DirectoryInfo(AppContext.BaseDirectory);
            while (dir != null)
            {
                var candidate = Path.Combine(dir.FullName, "browser-extension");
                if (Directory.Exists(candidate))
                    return candidate;
                dir = dir.Parent;
            }
            return null;
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

        /// <summary>
        /// Open a collection (album / playlist / artist) inside the current tab's
        /// frame. The card that was tapped already resolved it through the backend,
        /// so the page renders straight from the passed-in detail — no second
        /// round-trip. Players need their bar here: this page is not the full player.
        /// </summary>
        public void ShowCollection(CollectionRequest request)
        {
            if (request?.Detail == null)
                return;

            SetPlayerBarVisible(true);
            ContentFrame.Navigate(typeof(CollectionPage), request);
        }

        /// <summary>
        /// Show/hide the persistent player bar. The Now Playing page hides it
        /// (it renders its own full transport per the mockup — two side-by-side
        /// transports would duplicate every control); every other tab shows it.
        /// </summary>
        public void SetPlayerBarVisible(bool visible)
        {
            PlayerBar.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
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
            if (sender is RadioButton tab)
                NavigateToTab(tab.Tag as string);
        }

        /// <summary>
        /// Re-tapping the active tab returns to that tab's root page. Without it a
        /// collection sub-page (which lives inside the tab's frame) has no way back
        /// except its own Back button; idempotent, so a fresh selection — where
        /// Checked already navigated — does nothing extra.
        /// </summary>
        private void NavTab_Tapped(object sender, TappedRoutedEventArgs e)
        {
            if (sender is not RadioButton tab || ContentFrame == null)
                return;

            var target = PageForTag(tab.Tag as string);
            if (target != null && ContentFrame.Content?.GetType() != target)
                ContentFrame.Navigate(target);
        }

        private static Type PageForTag(string tag) => tag switch
        {
            "home" => typeof(HomePage),
            "search" => typeof(SearchPage),
            "library" => typeof(LibraryPage),
            "nowplaying" => typeof(NowPlayingPage),
            _ => null,
        };

        private void NavigateToTab(string tag)
        {
            var target = PageForTag(tag);
            if (target != null && ContentFrame != null)
                ContentFrame.Navigate(target);
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
