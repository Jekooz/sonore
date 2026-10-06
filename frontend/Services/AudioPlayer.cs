using System;
using System.IO;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using NAudio.Wave;

namespace YtMusicClient.Services
{
    /// <summary>
    /// Plays a resolved track URL through NAudio.
    ///
    /// Decode is left to Windows Media Foundation via StreamMediaFoundationReader,
    /// which (unlike MediaFoundationReader) accepts an arbitrary seekable Stream —
    /// so the source can be the progressive ChunkedAudioStream and audio starts
    /// before the track has finished downloading. Output goes through WaveOutEvent,
    /// which runs its own callback thread.
    ///
    /// Threading: Media Foundation's container parse and seek operations read
    /// through our network-backed stream and therefore BLOCK until the download
    /// has the bytes they need. None of that may ever run on the UI thread —
    /// doing so froze the whole app on song click. Setup, teardown and seeks all
    /// run on thread-pool threads; shared fields are only read or written under
    /// <see cref="_stateGate"/>; a session counter makes a superseded load discard
    /// itself instead of committing over the newer one.
    /// </summary>
    public sealed class AudioPlayer : IDisposable
    {
        // One client for the life of the player: connection pooling matters here
        // because every track is one long-lived response body.
        private readonly HttpClient _http = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };

        private readonly object _stateGate = new object();

        private WaveOutEvent _output;
        private StreamMediaFoundationReader _reader;
        private ChunkedAudioStream _source;
        private bool _disposed;

        // The stream being opened/buffered right now (set before MF's create
        // runs, which can take minutes on a slow link) — lets the UI show
        // buffering progress while setup is still in flight.
        private ChunkedAudioStream _pendingSource;

        // Bumped (under _stateGate) by every StopInternal() and PlayAsync() entry.
        // An in-flight PlayAsync whose session no longer matches must discard its
        // setup — a click during "opening the stream" must never let the stale
        // track commit and play over the one the user just chose.
        private int _session;

        // Persisted across tracks so a volume change while nothing plays is not lost.
        private float _volume = 1f;

        public bool IsPlaying { get; private set; }

        /// <summary>Current playback position, or zero when nothing is loaded.</summary>
        public TimeSpan Position => _reader?.CurrentTime ?? TimeSpan.Zero;

        /// <summary>Full track length once the container has been parsed.</summary>
        public TimeSpan Duration => _reader?.TotalTime ?? TimeSpan.Zero;

        /// <summary>Bytes downloaded so far — for a buffering indicator.</summary>
        public long BufferedLength => (_source ?? _pendingSource)?.BufferedLength ?? 0;

        /// <summary>Total bytes expected for the current track (0 before the stream opens).</summary>
        public long TotalLength => (_source ?? _pendingSource)?.Length ?? 0;

        /// <summary>Track finished on its own (not raised by Stop or Dispose).</summary>
        public event EventHandler PlaybackEnded;

        /// <summary>Decode or device failure, with the underlying error.</summary>
        public event EventHandler<Exception> PlaybackFailed;

        /// <summary>
        /// Loads and immediately starts a track. Disposes any track already playing.
        /// Only the header request awaits on the caller's thread; everything that
        /// can block on the network runs in the background.
        /// </summary>
        public async Task PlayAsync(string url)
        {
            if (_disposed) throw new ObjectDisposedException(nameof(AudioPlayer));
            if (string.IsNullOrWhiteSpace(url)) throw new ArgumentException("A stream URL is required.", nameof(url));

            StopInternal();

            int session;
            lock (_stateGate) session = _session;

            var source = new ChunkedAudioStream(_http, url);
            lock (_stateGate) _pendingSource = source;
            try
            {
                // Header request only — completes as soon as the CDN answers.
                await source.OpenAsync();

                bool committed = await Task.Run(() => SetupAndPlay(session, source));
                if (!committed)
                {
                    // Superseded by a newer PlayAsync/Stop while setting up:
                    // that call owns playback now, release this stream.
                    ClearPending(source);
                    source.Dispose();
                }
            }
            catch
            {
                // Never leak a half-constructed player: a failed load must not keep
                // a live HTTP response or MF session around.
                ClearPending(source);
                try { source.Dispose(); } catch { }
                throw;
            }
        }

        private void ClearPending(ChunkedAudioStream source)
        {
            lock (_stateGate)
            {
                if (ReferenceEquals(_pendingSource, source))
                    _pendingSource = null;
            }
        }

        /// <summary>
        /// Runs on a worker thread. Builds the MF reader and WaveOut device,
        /// starts audio, then commits under the session gate; returns false when
        /// this load was superseded and must be discarded by the caller.
        /// </summary>
        private bool SetupAndPlay(int session, ChunkedAudioStream source)
        {
            StreamMediaFoundationReader reader = null;
            WaveOutEvent output = null;
            bool stale = false;

            try
            {
                lock (_stateGate)
                {
                    stale = session != _session || _disposed;
                }
                if (stale) return false;

                // MF parses the container by reading through `source` right here;
                // on a slow connection this blocks this worker (never the UI).
                reader = new StreamMediaFoundationReader(
                    source,
                    new MediaFoundationReader.MediaFoundationReaderSettings());

                // MF's creation-time probing scans the stream's tail (dash-brand
                // boxes), leaving the source positioned at/near the end — the
                // first ReadSample then returns end-of-stream and WaveOut stops
                // after one buffer: playback "ends" instantly at 00:00. Rewind
                // explicitly before anything pulls audio.
                try
                {
                    reader.CurrentTime = TimeSpan.Zero;
                }
                catch (Exception ex)
                {
                    PlaybackLog.Write("rewind after MF create failed: " + ex.Message);
                }

                output = new WaveOutEvent
                {
                    DesiredLatency = 200,
                    NumberOfBuffers = 3,
                    Volume = _volume,
                };
                output.PlaybackStopped += Output_PlaybackStopped;
                output.Init(reader);
                output.Play();

                lock (_stateGate)
                {
                    stale = session != _session || _disposed;
                    if (!stale)
                    {
                        _source = source;
                        _reader = reader;
                        _output = output;
                        _pendingSource = null;
                        IsPlaying = true;
                    }
                }

                if (stale) return false;

                return true;
            }
            catch (Exception ex)
            {
                Release(output, reader);

                // Media Foundation collapses almost everything our stream does
                // into a generic 0x8000FFFF "Catastrophic failure". If the
                // download is what actually died, say that instead.
                if (!source.DownloadComplete)
                {
                    var reason = source.PumpError?.Message
                        ?? "the connection stopped delivering the rest of the track";
                    throw new IOException(
                        $"opening the track failed: {reason}",
                        source.PumpError ?? ex);
                }
                throw;
            }
            finally
            {
                if (stale)
                    Release(output, reader);
            }
        }

        /// <summary>Linear device volume 0..1; the UI applies its own perceptual curve.</summary>
        public void SetVolume(float volume)
        {
            volume = Math.Clamp(volume, 0f, 1f);
            lock (_stateGate)
            {
                _volume = volume;
                if (_output != null)
                    _output.Volume = volume;
            }
        }

        public void Pause()
        {
            lock (_stateGate)
            {
                if (_output == null || !IsPlaying) return;
                _output.Pause();
                IsPlaying = false;
            }
        }

        public void Resume()
        {
            lock (_stateGate)
            {
                if (_output == null || IsPlaying) return;
                _output.Play();
                IsPlaying = true;
            }
        }

        /// <summary>Jump within the track. Clamped to already-buffered bytes.</summary>
        public void Seek(TimeSpan position)
        {
            StreamMediaFoundationReader reader;
            lock (_stateGate) reader = _reader;
            if (reader == null) return;

            // Media Foundation's seek synchronously reads through the
            // network-backed source and can block until the download catches up —
            // never do that on the UI thread.
            Task.Run(() =>
            {
                try
                {
                    reader.CurrentTime = position;
                }
                catch (ObjectDisposedException)
                {
                    // The track was replaced while this seek was queued; nothing to do.
                }
                catch (Exception ex)
                {
                    PlaybackFailed?.Invoke(this, ex); // PlaybackService marshals to the UI thread
                }
            });
        }

        /// <summary>Stop and release the current track, keeping the player reusable.</summary>
        public void Stop() => StopInternal();

        private void StopInternal()
        {
            WaveOutEvent output;
            StreamMediaFoundationReader reader;
            ChunkedAudioStream source;

            lock (_stateGate)
            {
                _session++; // any in-flight PlayAsync must now discard its setup

                output = _output;
                reader = _reader;
                source = _source;

                _output = null;
                _reader = null;
                _source = null;
                _pendingSource = null;
                IsPlaying = false;
            }

            if (output == null) return;

            // Disposal joins WaveOut's thread and tears down the MF session, both
            // of which can wait on in-flight blocking reads — off the UI thread.
            Task.Run(() => Release(output, reader, source));
        }

        private void Release(WaveOutEvent output, StreamMediaFoundationReader reader, ChunkedAudioStream source = null)
        {
            if (output != null)
            {
                // Detach first: WaveOut raises PlaybackStopped from its own thread
                // during Stop/Dispose, and this object may already be superseded.
                try { output.PlaybackStopped -= Output_PlaybackStopped; } catch { }
                try { output.Stop(); } catch { }
                try { output.Dispose(); } catch { }
            }
            try { reader?.Dispose(); } catch { }
            try { source?.Dispose(); } catch { }
        }

        private void Output_PlaybackStopped(object sender, StoppedEventArgs e)
        {
            // WaveOutEvent also raises this on Stop()/Dispose(); those null _output
            // first (under the gate), so a matching live reference here means
            // playback ended by itself (end of track) or the device failed.
            bool ours;
            lock (_stateGate)
            {
                ours = ReferenceEquals(sender, _output);
                if (ours) IsPlaying = false;
            }
            if (!ours) return;

            if (e.Exception != null)
            {
                PlaybackFailed?.Invoke(this, e.Exception);
                return;
            }

            PlaybackEnded?.Invoke(this, EventArgs.Empty);
        }

        public void Dispose()
        {
            lock (_stateGate)
            {
                if (_disposed) return;
                _disposed = true;
            }
            StopInternal();
            _http.Dispose();
        }
    }
}
