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

        private readonly SidecarLauncher _launcher;

        public App()
        {
            this.InitializeComponent();
            _launcher = new SidecarLauncher();
        }

        protected override async void OnLaunched(LaunchActivatedEventArgs args)
        {
            // Show the window first; backend startup must never block or crash activation.
            var window = new MainWindow();
            window.Activate();
            window.Closed += (sender, e) => _launcher.Shutdown();

            // 8000 matches the backend's fixed port; only used if the sidecar fails to start,
            // in which case InitializeAsync reports the failure to the user.
            int port = 8000;
            try
            {
                port = await _launcher.StartupAsync();
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"Sidecar failed to start: {ex.Message}");
            }

            try
            {
                await window.InitializeAsync(port);
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"UI initialization failed: {ex.Message}");
            }
        }
    }
}
