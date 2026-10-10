using System;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
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

        // Single-instance guard. Two windows would fight over the one WASAPI
        // output device and over the shared backend, so a second launch asks the
        // running instance to come forward and then exits.
        private const string SingleInstanceMutexName = @"Local\YtMusicClient.SingleInstance";
        private const string ActivateEventName = @"Local\YtMusicClient.Activate";

        private Mutex _instanceMutex;
        private EventWaitHandle _activateSignal;
        private CancellationTokenSource _activateCts;

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

        /// <summary>
        /// Take the per-session single-instance mutex. True means we are the only
        /// instance and should carry on. A mutex failure is treated as "carry on"
        /// so a diagnostics problem can never stop the app from opening.
        /// </summary>
        private bool ClaimSingleInstance()
        {
            try
            {
                _instanceMutex = new Mutex(initiallyOwned: true, SingleInstanceMutexName, out bool createdNew);
                return createdNew;
            }
            catch (Exception ex)
            {
                LogCrash("ClaimSingleInstance", ex);
                return true;
            }
        }

        /// <summary>Ask the instance that owns the mutex to bring its window forward.</summary>
        private static void SignalExistingInstance()
        {
            try
            {
                if (EventWaitHandle.TryOpenExisting(ActivateEventName, out var signal))
                {
                    using (signal)
                        signal.Set();
                }
            }
            catch (Exception)
            {
                // Best effort: failing to raise the signal only means the user
                // has to click the existing window themselves.
            }
        }

        /// <summary>
        /// Listen for a second launch's focus request. The wait runs on a thread
        /// pool (background) thread so it can never hold the process open, and
        /// the window is touched only through the UI dispatcher.
        /// </summary>
        private void StartActivationListener()
        {
            try
            {
                _activateSignal = new EventWaitHandle(false, EventResetMode.AutoReset, ActivateEventName);
            }
            catch (Exception ex)
            {
                LogCrash("StartActivationListener", ex);
                return;
            }

            _activateCts = new CancellationTokenSource();
            var token = _activateCts.Token;

            _ = Task.Run(() =>
            {
                while (!token.IsCancellationRequested)
                {
                    try
                    {
                        if (_activateSignal.WaitOne(500))
                            Window?.DispatcherQueue.TryEnqueue(() => Window?.Activate());
                    }
                    catch (ObjectDisposedException)
                    {
                        return; // shutting down
                    }
                }
            });
        }

        private void StopActivationListener()
        {
            try { _activateCts?.Cancel(); } catch (Exception) { }
            _activateCts = null;

            try { _activateSignal?.Dispose(); } catch (Exception) { }
            _activateSignal = null;

            try { _instanceMutex?.Dispose(); } catch (Exception) { }
            _instanceMutex = null;
        }

        internal static void LogCrash(string stage, Exception ex)
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
            // Only one instance. A second launch must not open a second window
            // that shares one audio device and one backend with the first.
            if (!ClaimSingleInstance())
            {
                SignalExistingInstance();
                Exit();
                return;
            }

            // Show the window first; backend startup must never block or crash activation.
            MainWindow window = new MainWindow();
            Window = window;
            window.Activate();
            StartActivationListener();
            window.Closed += (sender, e) =>
            {
                // Stop audio and release the WASAPI/WaveOut device before the
                // sidecar goes away.
                Playback.Dispose();
                StopActivationListener();
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
