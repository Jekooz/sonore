using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Threading.Tasks;

namespace YtMusicClient.Services
{
    /// <summary>A track in the playback queue: what a click hands over as context.</summary>
    public sealed record QueueTrack(string VideoId, string Title, string Artist, string ArtworkUrl);

    /// <summary>
    /// The app's single playback pipeline, owned by <see cref="App.Playback"/> and
    /// observed by NowPlayingPage:
    ///
    ///   1. resolve a signed stream URL through the sidecar (yt-dlp),
    ///   2. stream it through the sparse disk cache (<see cref="RangeCachedStream"/>),
    ///   3. decode with Windows Media Foundation, 10-band EQ, and output via
    ///      WASAPI (<see cref="AudioEngine"/>).
    ///
    /// Play requests are issued from the UI thread and every continuation resumes
    /// there, so state changes are serialized; a generation counter drops any
    /// request that was superseded by a newer click before it finished resolving.
    /// The engine raises its own events from audio threads, so those are
    /// marshalled onto the UI dispatcher before they leave this class.
    /// </summary>
    public sealed class PlaybackService : INotifyPropertyChanged, IDisposable
    {
        private readonly AudioEngine _engine = new AudioEngine();

        private int _generation;     // stale async flows give up silently
        private string _currentUrl;  // signed URL of the loaded track
        private bool _finished;      // track played to the end
        private string _statusText = "";

        // Volume 0..1 (the engine applies the perceptual v³ curve); persisted via the shell VM.
        private float _volume = 0.8f;

        // Rapid Next/Previous clicks: a click within this window of the previous
        // one on the SAME track is ignored — stale resolves are already dropped
        // by _generation, this just stops five identical requests from launching.
        private DateTime _lastPlayRequestUtc = DateTime.MinValue;
        private string _lastPlayRequestVideoId;

        // History for Previous-button semantics (restart vs go back).
        private readonly List<(string VideoId, string Title, string Artist, string Artwork)> _history = new();

        // The playback queue, in order, with the position of the track now playing.
        // Filled by the list overload of PlayAsync; a standalone play leaves it empty
        // (or re-aims _queueIndex when the track happens to be part of the queue).
        private readonly List<QueueTrack> _queue = new();
        private int _queueIndex = -1;

        // Every state transition lands here so a "it didn't play" report can be
        // diagnosed after the fact (same idea as the sidecar's backend log).
        private static void Log(string message) => PlaybackLog.Write(message);

        public event PropertyChangedEventHandler PropertyChanged;

        /// <summary>Raised on the UI thread after any playback state change.</summary>
        public event EventHandler StateChanged;

        /// <summary>Set by the shell: plays the next track in the queue.</summary>
        public Action Next;

        /// <summary>True when a queue exists and a further track follows the current one.</summary>
        public bool HasNext => _queueIndex + 1 < _queue.Count;

        /// <summary>Set by the shell: Previous-button semantics (restart vs history).</summary>
        public Action PreviousByHistory;

        // ---------------- now-playing state ----------------

        public string VideoId { get; private set; }
        public string Title { get; private set; } = "";
        public string Artist { get; private set; } = "";
        public string ArtworkUrl { get; private set; } = "";

        public bool HasTrack => !string.IsNullOrEmpty(VideoId);
        public bool IsPlaying => _engine.IsPlaying;

        /// <summary>True while a stream is being resolved or buffered.</summary>
        public bool IsBusy { get; private set; }

        /// <summary>Empty during normal playback; otherwise a user-readable problem/state.</summary>
        public string StatusText => _statusText;

        public TimeSpan Position => _engine.Position;
        public TimeSpan Duration => _engine.Duration;

        /// <summary>Cached fraction 0..1 for seek-bar segments (no byte counts in UI).</summary>
        public double BufferedFraction => _engine.CachedFraction;

        /// <summary>Volume 0..1. The engine applies the perceptual v³ curve.</summary>
        public float Volume
        {
            get => _volume;
            set
            {
                _volume = Math.Clamp(value, 0f, 1f);
                _engine.SetVolume(_volume);
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Volume)));
            }
        }

        /// <summary>Seconds into the current track, or 0.</summary>
        public double PositionSeconds => Position.TotalSeconds;

        /// <summary>Track length in seconds once known, or 0.</summary>
        public double DurationSeconds => Duration.TotalSeconds;

        public PlaybackService()
        {
            _engine.Ended += Player_PlaybackEnded;
            _engine.Failed += Player_PlaybackFailed;
        }

        // ---------------- commands (always called on the UI thread) ----------------

        /// <summary>
        /// Start a track with the list it came from as context: that list becomes
        /// the queue, and Next / auto-advance walk it from the clicked track on.
        /// A single-track context plays standalone (Next disabled).
        /// </summary>
        public async Task PlayAsync(IReadOnlyList<QueueTrack> context, int startIndex)
        {
            if (context is not { Count: > 0 })
                return;

            _queue.Clear();
            _queue.AddRange(context);
            _queueIndex = Math.Clamp(startIndex, 0, context.Count - 1);

            var track = _queue[_queueIndex];
            await PlayAsync(track.VideoId, track.Title, track.Artist, track.ArtworkUrl);
        }

        /// <summary>
        /// Load and start a track. Replaces whatever is current; any in-flight
        /// resolve for a previously clicked track is abandoned.
        /// </summary>
        public async Task PlayAsync(string videoId, string title, string artist, string artworkUrl)
        {
            if (string.IsNullOrWhiteSpace(videoId))
                return;

            int generation = ++_generation;
            _finished = false;

            // Keep the queue honest: any direct play (Previous-from-history,
            // a later "play this one alone") re-aims the queue at this track
            // when it is part of the current context — searching forward from
            // the current index first, so a repeated track never hops back.
            // A track outside the queue is a standalone play: the stale list
            // must not resurrect itself via auto-advance, so drop it. One
            // branch here covers every play path — they all route through.
            int queueIdx = _queue.FindIndex(_queueIndex, t => t.VideoId == videoId);
            if (queueIdx < 0)
                queueIdx = _queue.FindIndex(t => t.VideoId == videoId);
            if (queueIdx >= 0)
                _queueIndex = queueIdx;
            else
            {
                _queue.Clear();
                _queueIndex = -1;
            }

            // Debounce: same track requested again within 700 ms of the last
            // request — treat as an accidental double-click and ignore.
            if (videoId == _lastPlayRequestVideoId &&
                (DateTime.UtcNow - _lastPlayRequestUtc).TotalMilliseconds < 700)
            {
                Log($"debounced duplicate play request for {videoId}");
                return;
            }
            _lastPlayRequestUtc = DateTime.UtcNow;
            _lastPlayRequestVideoId = videoId;

            Log($"play requested: {videoId} \"{title}\"");

            // Silence the old track right away: keeping it alive until the new
            // stream resolves would play audio that contradicts the UI, and the
            // cleared URL makes TogglePlayPause a no-op while resolving.
            _engine.Stop();
            _currentUrl = null;

            VideoId = videoId;
            Title = string.IsNullOrWhiteSpace(title) ? "Unknown track" : title;
            Artist = artist ?? "";
            ArtworkUrl = artworkUrl ?? "";
            IsBusy = true;
            _statusText = "Resolving stream…";
            NotifyState();

            if (App.ApiClient == null)
            {
                IsBusy = false;
                _statusText = "The backend is not ready yet — try again in a moment.";
                NotifyState();
                return;
            }

            try
            {
                var stream = await App.ApiClient.GetStreamUrlAsync(videoId);
                if (generation != _generation) { Log("superseded during resolve"); return; } // a newer click owns playback now

                _currentUrl = stream.Url;
                Log("stream resolved; opening player");
                _statusText = "Buffering…";
                NotifyState();

                await _engine.LoadAsync(stream.Url);
                if (generation != _generation) { Log("superseded during player setup"); return; } // ditto: never stop the newer track

                IsBusy = false;
                _statusText = "";
                Log("playing");

                if (HasNext)
                    _ = PrefetchNextAsync();

                // History for Previous: record only committed, non-duplicate plays.
                if (_history.Count == 0 || _history[^1].VideoId != videoId)
                    _history.Add((videoId, Title, Artist, ArtworkUrl));
                if (_history.Count > 50)
                    _history.RemoveAt(0);

                NotifyState();
            }
            catch (Exception ex)
            {
                if (generation != _generation) { Log($"superseded failure ignored: {ex.Message}"); return; }

                // Nothing may keep playing behind an error the user is looking at.
                _engine.Stop();
                IsBusy = false;
                _statusText = "Playback failed: " + FirstLine(ex.Message);
                Log("FAILED:\n" + ex);
                NotifyState();
            }
        }

        public void TogglePlayPause()
        {
            if (!HasTrack)
                return;

            if (_finished)
            {
                // Finished tracks cannot resume from a stopped WaveOut session —
                // go through the full load path again (the backend serves the
                // cached URL, so this is fast).
                _ = PlayAsync(VideoId, Title, Artist, ArtworkUrl);
                return;
            }

            if (_engine.IsPlaying)
            {
                _engine.Pause();
                Log("paused");
            }
            else if (_currentUrl != null)
            {
                _engine.Play();
                Log("resumed");
            }

            NotifyState();
        }

        /// <summary>Jump within the current track (clamped by the player).</summary>
        public void Seek(TimeSpan position)
        {
            if (!HasTrack || _finished)
                return;
            Log($"seek {position.TotalSeconds:F0}s");
            _engine.Seek(position);
            NotifyState();
        }

        /// <summary>Play the next track in the queue; no-op at the end of it.</summary>
        public void PlayNext()
        {
            if (!HasNext)
                return;

            _queueIndex++;
            var track = _queue[_queueIndex];
            Log($"next: queue[{_queueIndex}] {track.VideoId}");
            _ = PlayAsync(track.VideoId, track.Title, track.Artist, track.ArtworkUrl);
        }

        /// <summary>
        /// Restart the current track when more than ~3 s in, otherwise hop to the
        /// previous entry in history (the caller supplies the queue context).
        /// </summary>
        public void Previous(Func<string, string, string, string, Task> playTrack)
        {
            if (Position.TotalSeconds > 3)
            {
                Seek(TimeSpan.Zero);
                return;
            }

            // Walk back past the current track to the previous distinct one.
            for (int i = _history.Count - 2; i >= 0; i--)
            {
                if (_history[i].VideoId == VideoId)
                    continue;
                string id = _history[i].VideoId;
                string t = _history[i].Title;
                string a = _history[i].Artist;
                string art = _history[i].Artwork;
                _ = playTrack(id, t, a, art);
                return;
            }

            // No earlier track — restart.
            Seek(TimeSpan.Zero);
        }

        /// <summary>
        /// Resolve and warm the next queue track now, so the hand-off at
        /// end-of-track starts without a resolve round-trip.
        /// ponytail: fires at track start; Phase 6 moves it to 50% played.
        /// </summary>
        private async Task PrefetchNextAsync()
        {
            try
            {
                var next = _queue[_queueIndex + 1];
                var stream = await App.ApiClient.GetStreamUrlAsync(next.VideoId);
                await _engine.PrefetchNextAsync(stream.Url);
                Log($"prefetched next: {next.VideoId}");
            }
            catch (Exception ex)
            {
                Log("prefetch failed: " + ex.Message);
            }
        }

        /// <summary>Release the audio device and stop everything.</summary>
        public void Dispose()
        {
            _generation++;
            _engine.Dispose();
        }

        // ---------------- player events (audio thread → UI thread) ----------------

        private void Player_PlaybackEnded(object sender, EventArgs e)
        {
            RunOnUi(() =>
            {
                Log("ended (end of track)");

                // Auto-advance walks the queue; a standalone track just rests at Finished.
                if (HasNext)
                {
                    PlayNext();
                    return;
                }

                _finished = true;
                _statusText = "Finished";
                NotifyState();
            });
        }

        private void Player_PlaybackFailed(object sender, Exception ex)
        {
            RunOnUi(() =>
            {
                IsBusy = false;
                _statusText = "Playback error: " + FirstLine(ex.Message);
                Log("PLAYER FAILED:\n" + ex);
                NotifyState();
            });
        }

        // ---------------- helpers ----------------

        private void NotifyState()
        {
            RunOnUi(() =>
            {
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(VideoId)));
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Title)));
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Artist)));
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(ArtworkUrl)));
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(HasTrack)));
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsPlaying)));
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsBusy)));
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(HasNext)));
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(StatusText)));
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Position)));
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Duration)));
                StateChanged?.Invoke(this, EventArgs.Empty);
            });
        }

        private static void RunOnUi(Action action)
        {
            var queue = App.Window?.DispatcherQueue;
            if (queue == null || queue.HasThreadAccess)
                action();
            else
                _ = queue.TryEnqueue(() => action());
        }

        private static string FirstLine(string message)
        {
            if (string.IsNullOrWhiteSpace(message))
                return "Unknown error.";
            var msg = message.Trim();
            int cut = msg.IndexOfAny(new[] { '\r', '\n' });
            return cut > 0 ? msg.Substring(0, cut) : msg;
        }
    }
}
