using System;
using System.Diagnostics;
using Microsoft.UI.Xaml;
using YtMusicClient.Services;
using YtMusicClient.Views;

namespace YtMusicClient
{
    public sealed partial class App : Application
    {
        // Shared shell state (auth status, greeting) bound by the pages.
        public static ViewModels.MainShellViewModel ShellViewModel { get; } = new ViewModels.MainShellViewModel();

        // Shared API client for the running sidecar; set by MainWindow.InitializeAsync.
        public static ApiClient ApiClient { get; set; }

        /// <summary>The one bindable playback state; bar and Now Playing bind only to this.
        /// Declared before Playback: the service's constructor reads it.</summary>
        public static PlayerState PlayerState { get; } = new PlayerState();

        /// <summary>The observable queue (Current + Upcoming) for the queue panel and transport.</summary>
        public static QueueManager Queue { get; } = new QueueManager();

        // One playback pipeline for the whole app (resolve → engine → WASAPI),
        // observed by NowPlayingPage and driven by the list pages.
        public static PlaybackService Playback { get; } = new PlaybackService();

        // The main window, so pages can open dialogs / the sign-in window from it.
        public static Window Window { get; set; }

        private readonly SidecarLauncher _launcher;

        public App()
        {
            // WinUI stowed exceptions (0xC000027B) kill the process with no trace
            // anywhere — no event-log entry, no .NET exception. Log them (without
            // setting Handled) so a crash can be diagnosed after the fact, mirroring
            // the sidecar/playback logs in %TEMP%.
            this.UnhandledException += (s, e) =>
                LogCrash($"UnhandledException (Handled={e.Handled})", e.Exception ?? new Exception(e.Message));

            this.InitializeComponent();

            _launcher = new SidecarLauncher();
        }

        private static void LogCrash(string stage, Exception ex)
        {
            try
            {
                System.IO.File.AppendAllText(
                    System.IO.Path.Combine(System.IO.Path.GetTempPath(), "ytmusic_crash.log"),
                    $"{DateTime.Now:o} {stage}:\r\n{ex}\r\n\r\n");
            }
            catch
            {
                // Diagnostics must never break startup.
            }
        }

        protected override async void OnLaunched(LaunchActivatedEventArgs args)
        {
            // Show the window first; backend startup must never block or crash activation.
            MainWindow window = new MainWindow();
            Window = window;
            window.Activate();
            window.Closed += (sender, e) =>
            {
                // Stop audio and release the WASAPI/WaveOut device before the
                // sidecar goes away.
                Playback.Dispose();
                _launcher.Shutdown();
            };

            // No guessed fallback port: silently defaulting to 8000 hid real
            // startup failures, which only showed up later as "connection refused"
            // when the user tried to sign in. Pass the failure to the UI instead.
            int port = 0;
            string sidecarError = null;
            try
            {
                port = await _launcher.StartupAsync();
            }
            catch (Exception ex)
            {
                sidecarError = ex.Message;
                Debug.WriteLine($"Sidecar failed to start: {ex.Message}");
            }

            try
            {
                await window.InitializeAsync(port, sidecarError);
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"UI initialization failed: {ex.Message}");
            }
        }
    }
}
