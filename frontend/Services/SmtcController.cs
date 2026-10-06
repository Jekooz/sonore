using System;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Storage.Streams;
using Windows.Media;
using WinRT.Interop;

namespace YtMusicClient.Services
{
    /// <summary>
    /// Bridges <see cref="PlaybackService"/> to System Media Transport Controls:
    /// media keys (hardware + keyboard), the volume-flyout and lock-screen Now
    /// Playing widgets, and the wired-up Play/Pause/Next/Previous buttons there.
    /// The system renders its own UI from Title/Artist/Thumbnail — no XAML cost.
    /// All updates are marshalled to the window's dispatcher because SMTC objects
    /// have UI-thread affinity.
    /// </summary>
    public sealed class SmtcController : IDisposable
    {
        private readonly PlaybackService _playback;
        private readonly DispatcherQueue _dispatcher;
        private readonly SystemMediaTransportControls _smtc;

        private string _boundVideoId;
        private string _boundArtworkUrl;

        public SmtcController(PlaybackService playback, Window window)
        {
            _playback = playback;
            _dispatcher = window.DispatcherQueue;

            // WinUI 3 windows are Win32 windows: SMTC comes from the WinRT interop
            // factory on the native window handle.
            _smtc = SystemMediaTransportControlsInterop.GetForWindow(WindowNative.GetWindowHandle(window));
            _smtc.IsEnabled = true;
            _smtc.IsPlayEnabled = true;
            _smtc.IsPauseEnabled = true;
            // Next has no target until the queue panel lands (later increment).
            _smtc.IsNextEnabled = playback.Next != null;
            _smtc.IsPreviousEnabled = true;

            _smtc.ButtonPressed += Smtc_ButtonPressed;

            playback.StateChanged += Playback_StateChanged;
            UpdateFrom(playback, force: true);
        }

        private void Playback_StateChanged(object sender, EventArgs e)
            => UpdateFrom(_playback, force: false);

        private void UpdateFrom(PlaybackService playback, bool force)
        {
            _dispatcher.TryEnqueue(() =>
            {
                try
                {
                    // Metadata only when the track identity changes.
                    if (force || !string.Equals(_boundVideoId, playback.VideoId, StringComparison.Ordinal))
                    {
                        _boundVideoId = playback.VideoId;
                        _boundArtworkUrl = null;

                        var props = _smtc.DisplayUpdater;
                        props.Type = MediaPlaybackType.Music;
                        props.MusicProperties.Title = playback.HasTrack ? playback.Title ?? "" : "";
                        props.MusicProperties.Artist = playback.HasTrack ? playback.Artist ?? "" : "";
                        props.Thumbnail = null;
                        props.Update();
                    }

                    // Artwork can arrive slightly after titles (or be swapped on
                    // an upgraded resolution) — refresh whenever its URL changes.
                    if (playback.HasTrack &&
                        !string.IsNullOrEmpty(playback.ArtworkUrl) &&
                        !string.Equals(_boundArtworkUrl, playback.ArtworkUrl, StringComparison.Ordinal))
                    {
                        _boundArtworkUrl = playback.ArtworkUrl;
                        try
                        {
                            var props = _smtc.DisplayUpdater;
                            var stream = RandomAccessStreamReference.CreateFromUri(new Uri(playback.ArtworkUrl));
                            props.Thumbnail = stream;
                            props.Update();
                        }
                        catch
                        {
                            // A bad artwork URL must not take SMTC down with it.
                        }
                    }

                    _smtc.PlaybackStatus = playback.IsPlaying
                        ? MediaPlaybackStatus.Playing
                        : (playback.HasTrack && !playback.IsBusy ? MediaPlaybackStatus.Paused : MediaPlaybackStatus.Closed);
                }
                catch
                {
                    // SMTC must never break playback; worst case the widget is stale.
                }
            });
        }

        private void Smtc_ButtonPressed(SystemMediaTransportControls sender, SystemMediaTransportControlsButtonPressedEventArgs args)
        {
            // SMTC events arrive off the UI thread; PlaybackService is safe to call
            // from any thread (it marshals internally), but go through the dispatcher
            // anyway so ordering with UI-driven commands is preserved.
            _dispatcher.TryEnqueue(() =>
            {
                switch (args.Button)
                {
                    case SystemMediaTransportControlsButton.Play:
                        _playback.TogglePlayPause();
                        break;
                    case SystemMediaTransportControlsButton.Pause:
                        _playback.TogglePlayPause();
                        break;
                    case SystemMediaTransportControlsButton.Next:
                        if (_playback.Next != null) _playback.Next();
                        break;
                    case SystemMediaTransportControlsButton.Previous:
                        _playback.PreviousByHistory?.Invoke();
                        break;
                }
            });
        }

        public void Dispose()
        {
            _playback.StateChanged -= Playback_StateChanged;
            try
            {
                _smtc.ButtonPressed -= Smtc_ButtonPressed;
            }
            catch { }
        }
    }
}
