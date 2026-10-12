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

        // Rapid Next/Previous clicks: a click within this window of the previous
        // one on the SAME track is ignored — stale resolves are already dropped
        // by _generation, this just stops five identical requests from launching.
        private DateTime _lastPlayRequestUtc = DateTime.MinValue;
        private string _lastPlayRequestVideoId;

        // History for Previous-button semantics (restart vs go back).
        private readonly List<(string VideoId, string Title, string Artist, string Artwork)> _history = new();

        // Shuffle markers (this session): tracks already played in the current
        // shuffle pass, so repeats only come back on repeat-all wrap.
        private readonly HashSet<string> _playedShuffle = new();

        /// <summary>The VideoId for which we already fired the 50%-prefetch on this track.</summary>
        private string _prefetchFiredFor;

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

        /// <summary>Reset playback debug state between runs (used by diagnostics / tests).</summary>
        public void ResetDebugState()
        {
            _generation++;
            _finished = false;
            _statusText = "";
            _currentUrl = null;
            _prefetchFiredFor = null;
            _lastPlayRequestUtc = DateTime.MinValue;
            _lastPlayRequestVideoId = null;
        }

        /// <summary>
        /// True when PlayNext() would actually start a track: a later queue entry, a
        /// repeat-all wrap, a shuffle jump elsewhere, or a repeat-one reload. The Next
        /// controls and the SMTC next button both gate on this answer, so it has to
        /// describe what the service really does. Asking only "is there an Upcoming
        /// entry?" greyed Next out at the end of a repeat-all queue even though pressing
        /// it — and auto-advance — would wrap to the first track.
        /// One deliberate approximation: with shuffle and repeat off, every other track
        /// may already have been played, in which case PlayNext still declines. A control
        /// that is enabled and then does nothing is the milder failure of the two.
        /// </summary>
        public bool HasNext
        {
            get
            {
                var state = App.PlayerState;

                if (state.Repeat == RepeatMode.One)
                    return HasTrack;                                  // PlayNext reloads this track
                if (_queueIndex + 1 < _queue.Count)
                    return true;                                      // a later entry exists
                if (state.Repeat == RepeatMode.All && _queue.Count > 0)
                    return true;                                      // wraps to the first entry
                if (state.Shuffle && _queue.Count > 1)
                    return true;                                      // shuffle may jump elsewhere
                return false;
            }
        }

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

        /// <summary>Seconds into the current track, or 0.</summary>
        public double PositionSeconds => Position.TotalSeconds;

        /// <summary>Track length in seconds once known, or 0.</summary>
        public double DurationSeconds => Duration.TotalSeconds;

        /// <summary>The current track art, for the mini-chip + carousel refresh path.
        /// Exposed for the Now Playing transport pill and the 3-card fan carousel so
        /// they can observe art swaps without re-parsing PlayerState.Track.</summary>
        public string CurrentArtworkUrl => ArtworkUrl;

        public PlaybackService()
        {
            _engine.Ended += Player_PlaybackEnded;
            _engine.Failed += Player_PlaybackFailed;
            _engine.PlaybackTick += Engine_PlaybackTick;

            // Volume lives in PlayerState (bindable + persisted); the engine applies the curve.
            // Repeat and shuffle change how far Next can reach with no queue change at all,
            // so the capability is refreshed from here too. A named handler rather than a
            // lambda so Dispose can unsubscribe it: a discarded service must not keep
            // writing into the shared queue (that also keeps the tests independent).
            App.PlayerState.PropertyChanged += OnPlayerStateChanged;
            _engine.SetVolume((float)App.PlayerState.Volume);
        }

        private void OnPlayerStateChanged(object sender, PropertyChangedEventArgs e)
        {
            switch (e.PropertyName)
            {
                case nameof(PlayerState.Volume):
                    _engine.SetVolume((float)App.PlayerState.Volume);
                    break;

                case nameof(PlayerState.Repeat):
                case nameof(PlayerState.Shuffle):
                    App.Queue.CanAdvance = HasNext;
                    break;
            }
        }

        /// <summary>Volume entry point for PlayerState (0..1, perceptual curve applied in the engine).</summary>
        public void SetVolume(double volume01) => _engine.SetVolume((float)Math.Clamp(volume01, 0, 1));

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

            // Debounce FIRST, before anything at all is touched: a duplicate click has
            // to be a true no-op. This gate used to sit below the generation bump, so
            // the request it was meant to ignore had already superseded the load it was
            // supposed to protect: the first click's resolve then hit its own
            // "superseded during resolve" check, aborted itself, and playback never
            // started — leaving the page on "Resolving stream…" with the play button
            // disabled, because IsBusy was never cleared by anything else. Sitting above
            // the reset also stops an ignored duplicate from clearing _finished, which
            // would have made a played-out track look resumable.
            if (videoId == _lastPlayRequestVideoId &&
                (DateTime.UtcNow - _lastPlayRequestUtc).TotalMilliseconds < 700)
            {
                Log($"debounced duplicate play request for {videoId}");
                return;
            }
            _lastPlayRequestUtc = DateTime.UtcNow;
            _lastPlayRequestVideoId = videoId;

            _prefetchFiredFor = null; // new track: re-evaluate prefetch at 50%
            int generation = ++_generation;
            _finished = false;

            // Keep the queue honest: any direct play (Previous-from-history,
            // a later "play this one alone") re-aims the queue at this track
            // when it is part of the current context — searching forward from
            // the current index first, so a repeated track never hops back.
            // A track outside the queue is a standalone play: the stale list
            // must not resurrect itself via auto-advance, so drop it. One
            // branch here covers every play path — they all route through.
            // Guarded because List.FindIndex throws ArgumentOutOfRangeException for a
            // negative start index, and _queueIndex IS -1 for a standalone play (that
            // branch below drops the stale queue). Every caller of that path is
            // fire-and-forget (`_ = PlayAsync(...)`), so the throw was invisible: a
            // standalone track could never be reloaded — play-after-finish and
            // Previous-from-history appeared to do nothing at all. Found by the Batch 5
            // regression tests; the fallback below still searches the whole queue, so
            // the "never hop back" intent is unchanged.
            int queueIdx = _queueIndex >= 0 && _queueIndex < _queue.Count
                ? _queue.FindIndex(_queueIndex, t => t.VideoId == videoId)
                : -1;
            if (queueIdx < 0)
                queueIdx = _queue.FindIndex(t => t.VideoId == videoId);
            if (queueIdx >= 0)
                _queueIndex = queueIdx;
            else
            {
                _queue.Clear();
                _queueIndex = -1;
            }

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

                // Prefetch moves to 50% played (Phase 6): starting the resolve too
                // early wastes the connection slot and the warm can cool before the
                // hand-off; starting too late adds a gap at end-of-track. 50% gives
                // the second half of the track to resolve + warm the next one.
                // Shuffle is excluded: a random next would miss the pre-warmed track.

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
                // The URL has to go with it: Stop() releases the output, so nothing is
                // loaded any more. Leaving it set made TogglePlayPause take its "resume"
                // branch and call Play() on a session that no longer existed — another
                // silent no-op, and the reason a failed track could not be retried.
                _currentUrl = null;
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

            // Nothing loaded to resume, or the track already played out: both mean
            // "load it again". The first case is a failed (or superseded) resolve — and
            // there CanToggle is HasTrack && !IsBusy, so the play button is ENABLED, yet
            // neither test below matched and the press did nothing at all. The track was
            // a dead end the user could only escape by finding it in a list again.
            // _finished is checked as well because a finished track cannot resume from a
            // stopped WaveOut session. The retry deliberately clears the duplicate gate:
            // pressing play is a deliberate act, not the accidental double-click that
            // gate exists to absorb. The !IsBusy guard matters — without it the Space
            // accelerator (which is not state-gated) would restart an in-flight resolve
            // every time it was pressed, and the load would never finish.
            if (_finished || (!IsBusy && _currentUrl == null))
            {
                // Both cases go back through the full load path; the backend serves a
                // cached URL, so this is fast.
                Log(_finished ? "reloading finished track" : "retrying load with nothing loaded");
                _lastPlayRequestVideoId = null;
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

        /// <summary>
        /// Play the next track: repeat-one reloads, shuffle picks a random
        /// unplayed track, repeat-all wraps, otherwise walk forward. Returns
        /// false when the queue is exhausted and repeat is off.
        /// ponytail: shuffle is a random pick; a proper shuffle bag lands
        /// with the queue panel (Phase 4).
        /// </summary>
        public bool PlayNext()
        {
            var state = App.PlayerState;

            if (state.Repeat == RepeatMode.One && HasTrack)
            {
                Log("repeat one: reloading current track");
                _ = PlayAsync(VideoId, Title, Artist, ArtworkUrl);
                return true;
            }

            int next = -1;
            if (state.Shuffle && _queue.Count > 1)
            {
                var candidates = new List<int>();
                for (int i = 0; i < _queue.Count; i++)
                    if (i != _queueIndex && !_playedShuffle.Contains(_queue[i].VideoId))
                        candidates.Add(i);
                if (candidates.Count == 0 && state.Repeat == RepeatMode.All)
                {
                    _playedShuffle.Clear();
                    for (int i = 0; i < _queue.Count; i++)
                        if (i != _queueIndex)
                            candidates.Add(i);
                }
                if (candidates.Count > 0)
                    next = candidates[Random.Shared.Next(candidates.Count)];
            }
            else if (_queueIndex + 1 < _queue.Count)
            {
                next = _queueIndex + 1;
            }
            else if (state.Repeat == RepeatMode.All && _queue.Count > 0)
            {
                next = 0;
            }

            if (next < 0)
                return false;

            _prefetchFiredFor = null; // advancing to a new track: re-evaluate prefetch at 50%
            _queueIndex = next;
            var track = _queue[_queueIndex];
            _playedShuffle.Add(track.VideoId);
            Log($"next: queue[{_queueIndex}] {track.VideoId}");
            _ = PlayAsync(track.VideoId, track.Title, track.Artist, track.ArtworkUrl);
            return true;
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
            App.PlayerState.PropertyChanged -= OnPlayerStateChanged;
            _engine.Dispose();
        }

        // ---------------- player events (audio thread → UI thread) ----------------

        private void Player_PlaybackEnded(object sender, EventArgs e)
        {
            RunOnUi(() =>
            {
                Log("ended (end of track)");

                // Auto-advance honors repeat/shuffle; PlayNext answers whether
                // anything actually started — otherwise the track rests at Finished.
                if (HasNext || App.PlayerState.Repeat != RepeatMode.Off || App.PlayerState.Shuffle)
                {
                    if (PlayNext())
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

        /// <summary>
        /// Push the full state snapshot into PlayerState + QueueManager (the
        /// single bindable source both screens bind to), then raise StateChanged
        /// for non-binding listeners (SMTC).
        /// </summary>
        private void NotifyState()
        {
            RunOnUi(() =>
            {
                var state = App.PlayerState;
                state.Track = HasTrack ? new QueueTrack(VideoId, Title, Artist, ArtworkUrl) : null;
                state.IsPlaying = _engine.IsPlaying;
                state.IsBusy = IsBusy;
                state.IsFinished = _finished;
                state.Position = Position;
                state.Duration = Duration;
                state.BufferedFraction = BufferedFraction;
                state.StatusText = _statusText;
                App.Queue.Sync(_queue, _queueIndex);
                App.Queue.CanAdvance = HasNext;
                StateChanged?.Invoke(this, EventArgs.Empty);
            });
        }

        /// <summary>Engine 4 Hz heartbeat: position/duration/cached → PlayerState.
        /// Also fires the 50%-prefetch for the next track once the current one
        /// crosses the halfway mark (Phase 6).</summary>
        private void Engine_PlaybackTick(object sender, EventArgs e)
        {
            RunOnUi(() =>
            {
                var state = App.PlayerState;
                state.Position = _engine.Position;
                state.Duration = _engine.Duration;
                state.BufferedFraction = _engine.CachedFraction;

                // Prefetch the next track once the current one is halfway played
                // (Phase 6). Fires once per track; re-fires only after a new track
                // starts (which clears _prefetchFiredFor in PlayAsync/PlayNext).
                if (HasTrack && state.IsPlaying && _queueIndex + 1 < _queue.Count
                    && _prefetchFiredFor != _queue[_queueIndex].VideoId
                    && !App.PlayerState.Shuffle)
                {
                    double progress = state.Duration.TotalSeconds > 0
                        ? state.Position.TotalSeconds / state.Duration.TotalSeconds
                        : 0;
                    if (progress >= 0.5)
                    {
                        _prefetchFiredFor = _queue[_queueIndex].VideoId;
                        _ = PrefetchNextAsync();
                    }
                }
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
