using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;

namespace YtMusicClient.Views
{
    /// <summary>
    /// In-app Google sign-in.
    ///
    /// The user signs in inside an embedded WebView2 pointed at music.youtube.com —
    /// no external browser and no code to copy. Once sign-in is detected, every
    /// cookie we care about is pulled from the WebView2 CookieManager (which can
    /// read HttpOnly cookies such as __Secure-3PAPISID, unlike document.cookie)
    /// and handed to the backend, which encrypts it into the Windows credential
    /// store.
    ///
    /// Success is deliberately defined as "the backend would accept this": we only
    /// report signed-in while the view is actually on music.youtube.com AND all of
    /// the backend's REQUIRED_COOKIES are present. Checking on the log-in page
    /// itself is a false positive — Google sets plenty of session cookies during
    /// the form flow (SAPISID, APISID, SID) that never survive the redirect back
    /// to YouTube Music, which is what previously made sign-in look like it had
    /// worked when it had not.
    /// </summary>
    public sealed partial class SignInWindow : Window
    {
        private const string StartUrl = "https://music.youtube.com";
        private const string MusicHost = "music.youtube.com";
        private const string GoogleAccountsHost = "accounts.google.com";

        /// <summary>
        /// Mirrors REQUIRED_COOKIES in backend/services/ytmusic_client.py. The
        /// backend raises AuthError without these, so we must not claim success
        /// until all three are in hand.
        /// </summary>
        private static readonly string[] RequiredCookies =
        {
            "__Secure-3PAPISID",
            "SAPISID",
            "SID",
        };

        /// <summary>
        /// Cookies are taken from music.youtube.com ONLY.
        ///
        /// That is exactly the set a real browser sends when authenticating to
        /// YouTube Music. Merging in accounts.google.com on top used to overwrite
        /// the YouTube values with the Google-domain ones, and filtering through a
        /// name whitelist dropped cookies YouTube sets as part of the same session
        /// (__Secure-3PSIDTS, SIDCC, __Secure-3PSIDCC, VISITOR_PRIVACY_METADATA,
        /// __Secure-ROLLOUT_TOKEN). Forward the whole jar instead.
        /// </summary>
        private static readonly string[] CookieSources = { StartUrl };

        /// <summary>How long to keep polling before giving up (seconds).</summary>
        private const int CheckTimeoutSeconds = 60;

        private TaskCompletionSource<bool> _signInTask;
        private bool _completed;
        private bool _succeeded;
        private bool _checkRunning;
        private bool _recheckRequested;

        public SignInWindow()
        {
            InitializeComponent();
            Title = "Sign in with Google";
            AppWindow.Resize(new Windows.Graphics.SizeInt32(1000, 760));
        }

        public Task<bool> ShowAndWaitAsync()
        {
            if (_signInTask == null)
            {
                _signInTask = new TaskCompletionSource<bool>();
                Closed += SignInWindow_OnClosed;
                Activate();
                // Covers the "already signed in" case: the session cookies are
                // already there, so the first poll succeeds without any navigation.
                _ = CheckSignInStateAsync();
            }

            // Sign-in can be detected before anyone awaits (a cached session
            // resolves on the very first poll), so replay it rather than hang.
            if (_completed)
                _signInTask.TrySetResult(_succeeded);

            return _signInTask.Task;
        }

        private async void SignInWebView_NavigationStarting(WebView2 sender, CoreWebView2NavigationStartingEventArgs args)
        {
            StatusText.Text = "Loading…";
            await EnsureCoreWebView2Started();
        }

        private async void SignInWebView_NavigationCompleted(WebView2 sender, CoreWebView2NavigationCompletedEventArgs args)
        {
            await EnsureCoreWebView2Started();
            UpdateStatusForUrl(SignInWebView.Source);

            // Re-arm the poll on every arrival at YouTube Music. This is the only
            // place sign-in can legitimately land, so this is the only place we look.
            if (IsMusicHost(SignInWebView.Source))
                _ = CheckSignInStateAsync();
        }

        /// <summary>
        /// Polls the WebView2 cookie store until the session is real (or we time
        /// out). Re-entry while a poll is live just marks that another navigation
        /// happened, so the running poll restarts its timeout instead of both
        /// polls racing each other.
        /// </summary>
        private async Task CheckSignInStateAsync()
        {
            if (_checkRunning)
            {
                _recheckRequested = true;
                return;
            }

            _checkRunning = true;
            try
            {
                int elapsed = 0;

                while (!_completed && elapsed < CheckTimeoutSeconds)
                {
                    if (_recheckRequested)
                    {
                        _recheckRequested = false;
                        elapsed = 0;
                    }

                    // Never accept a session while sitting on the log-in form:
                    // that is exactly the false positive that broke this before.
                    if (IsMusicHost(SignInWebView.Source))
                    {
                        var cookies = await CaptureCookiesAsync();
                        if (IsCompleteSession(cookies))
                        {
                            Complete(true, cookies);
                            return;
                        }
                    }

                    await Task.Delay(1000);
                    elapsed++;
                }
            }
            finally
            {
                _checkRunning = false;
            }
        }

        private static bool IsCompleteSession(Dictionary<string, string> cookies)
        {
            if (cookies == null)
                return false;

            foreach (var name in RequiredCookies)
            {
                if (!cookies.TryGetValue(name, out var value) || string.IsNullOrEmpty(value))
                    return false;
            }

            return true;
        }

        private void UpdateStatusForUrl(Uri uri)
        {
            if (uri == null)
                return;

            if (IsGoogleAccountsHost(uri))
                StatusText.Text = "Enter your Google account details to continue.";
            else if (IsMusicHost(uri))
                StatusText.Text = "Waiting for sign-in…";
            else
                StatusText.Text = "";
        }

        private static bool IsGoogleAccountsHost(Uri uri) =>
            uri.Host.Equals(GoogleAccountsHost, StringComparison.OrdinalIgnoreCase);

        private static bool IsMusicHost(Uri uri) =>
            uri != null && uri.Host.EndsWith(MusicHost, StringComparison.OrdinalIgnoreCase);

        private async Task<Dictionary<string, string>> CaptureCookiesAsync()
        {
            var result = new Dictionary<string, string>(StringComparer.Ordinal);
            var webView2 = SignInWebView;

            if (webView2?.CoreWebView2 == null)
                return result;

            var manager = webView2.CoreWebView2.CookieManager;

            foreach (var url in CookieSources)
            {
                var cookies = await manager.GetCookiesAsync(url);
                if (cookies == null)
                    continue;

                foreach (var cookie in cookies)
                {
                    if (cookie == null || string.IsNullOrEmpty(cookie.Name) || string.IsNullOrEmpty(cookie.Value))
                        continue;

                    // Forward everything: no whitelist. The backend already builds
                    // the Cookie header and passes along extras it does not know.
                    result[cookie.Name] = cookie.Value;
                }
            }

            return result;
        }

        private async Task EnsureCoreWebView2Started()
        {
            if (SignInWebView.CoreWebView2 == null)
                await SignInWebView.EnsureCoreWebView2Async();
        }

        private void Complete(bool signedIn, Dictionary<string, string> cookies = null)
        {
            if (_completed)
                return;

            _completed = true;
            _succeeded = signedIn;
            Closed -= SignInWindow_OnClosed;

            CookiesCaptured?.Invoke(this, signedIn ? cookies : null);
            _signInTask?.TrySetResult(signedIn);

            Close();
        }

        public event EventHandler<Dictionary<string, string>> CookiesCaptured;

        private void SignInWindow_OnClosed(object sender, WindowEventArgs args)
        {
            Complete(false);
        }
    }
}
