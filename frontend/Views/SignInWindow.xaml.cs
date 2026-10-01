using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;

namespace YtMusicClient.Views
{
    /// <summary>
    /// "Sign in with Google" window: an embedded browser at music.youtube.com.
    /// The user signs in with their normal Google account — no device codes, no
    /// console, nothing to copy. When sign-in is detected, the browser cookies
    /// (including HttpOnly ones like __Secure-3PAPISID, which scripts cannot read)
    /// are pulled from the WebView2 CookieManager and handed to the backend, which
    /// stores them in the Windows Credential Locker.
    /// </summary>
    public sealed partial class SignInWindow : Window
    {
        private const string StartUrl = "https://music.youtube.com";
        private const string GoogleAccountsHost = "accounts.google.com";

        private TaskCompletionSource<bool> _signInTask;
        private bool _completed;

        public SignInWindow()
        {
            InitializeComponent();
            Title = "Sign in with Google";
            AppWindow.Resize(new Windows.Graphics.SizeInt32(1000, 760));
        }

        /// <summary>
        /// Shows the sign-in window and completes when the user is signed in
        /// (true) or closes the window without signing in (false).
        /// </summary>
        public Task<bool> ShowAndWaitAsync()
        {
            _signInTask = new TaskCompletionSource<bool>();
            Closed += SignInWindow_OnClosed;
            Activate();
            return _signInTask.Task;
        }

        private async void SignInWebView_NavigationStarting(CoreWebView2 sender, CoreWebView2NavigationStartingEventArgs args)
        {
            StatusText.Text = "Loading…";
            await EnsureCoreWebView2Started();
        }

        private async void SignInWebView_NavigationCompleted(CoreWebView2 sender, CoreWebView2NavigationCompletedEventArgs args)
        {
            await EnsureCoreWebView2Started();
            UpdateStatusForUrl(SignInWebView.Source);

            // Poll briefly after each navigation: Google redirects through several
            // URLs on the way in, and the final cookie set lands shortly after the
            // music.youtube.com page actually renders for a signed-in account.
            if (IsMusicHost(SignInWebView.Source))
                _ = CheckSignInStateAsync();
        }

        private async System.Threading.Tasks.Task CheckSignInStateAsync()
        {
            for (int attempt = 0; attempt < 10; attempt++)
            {
                if (_completed)
                    return;

                var cookies = await CaptureCookiesAsync();
                if (cookies.Count > 0)
                {
                    Complete(true, cookies);
                    return;
                }
                await System.Threading.Tasks.Task.Delay(1000);
            }
        }

        private void UpdateStatusForUrl(Uri uri)
        {
            if (uri == null)
                return;

            if (IsGoogleAccountsHost(uri))
                StatusText.Text = "Enter your Google account details to continue.";
            else if (IsMusicHost(uri))
                StatusText.Text = "Checking sign-in…";
            else
                StatusText.Text = "";
        }

        private static bool IsGoogleAccountsHost(Uri uri) =>
            uri.Host.Equals(GoogleAccountsHost, StringComparison.OrdinalIgnoreCase);

        private static bool IsMusicHost(Uri uri) =>
            uri.Host.EndsWith("music.youtube.com", StringComparison.OrdinalIgnoreCase);

        /// <summary>
        /// Reads all cookies for music.youtube.com (HttpOnly included) from the
        /// WebView2 profile. Returns an empty map while the user is not signed in,
        /// because ytmusicapi's required session cookies only exist once signed in.
        /// </summary>
        private async System.Threading.Tasks.Task<Dictionary<string, string>> CaptureCookiesAsync()
        {
            var result = new Dictionary<string, string>();
            var webView2 = SignInWebView;
            if (webView2?.CoreWebView2 == null)
                return result;

            // Must be called on the UI thread; CookieManager reads the live profile.
            var cookies = await webView2.CoreWebView2.CookieManager.GetCookiesAsync(StartUrl);
            foreach (var cookie in cookies)
            {
                if (string.IsNullOrEmpty(cookie?.Name) || string.IsNullOrEmpty(cookie.Value))
                    continue;
                result[cookie.Name] = cookie.Value;
            }
            return result;
        }

        private async System.Threading.Tasks.Task EnsureCoreWebView2Started()
        {
            if (SignInWebView.CoreWebView2 == null)
                await SignInWebView.EnsureCoreWebView2Async();
        }

        private void Complete(bool signedIn, Dictionary<string, string> cookies = null)
        {
            if (_completed)
                return;
            _completed = true;
            CookiesCaptured?.Invoke(this, cookies);
            _signInTask?.TrySetResult(signedIn);
            Closed -= SignInWindow_OnClosed;
            Close();
        }

        /// <summary>Carries the captured cookie map to the caller (MainWindow) on success.</summary>
        public event EventHandler<Dictionary<string, string>> CookiesCaptured;

        private void SignInWindow_OnClosed(object sender, WindowClosedEventArgs args)
        {
            Complete(false);
        }
    }
}