using System;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace YtMusicClient.Services
{
    /// <summary>
    /// The audio pipeline:
    ///   RangeCachedStream (sparse disk cache) → MediaFoundationReader (decode)
    ///   → Equalizer10 (10-band BiQuad) → VolumeSampleProvider → WasapiOut.
    ///
    /// API: LoadAsync(url), Play, Pause, Seek, SetVolume (perceptual v³),
    /// Position/Duration, a 4 Hz PlaybackTick event, Ended, Failed, and a
    /// Scrobbled event raised once per track at ≥50% or 4 minutes, whichever
    /// comes first. PrefetchNextAsync opens the next track's stream and warms
    /// ~2 MB, so the Ended hand-off starts without a resolve round-trip.
    ///
    /// Threading (ported from the proven AudioPlayer): Media Foundation's
    /// container parse reads through the network-backed stream and BLOCKS
    /// until the cache has the bytes, so setup/teardown/seeks always run on
    /// worker threads. A session counter makes a superseded load discard
    /// itself instead of committing over a newer one.
    /// </summary>
    public sealed class AudioEngine : IDisposable
    {
        private readonly HttpClient _http = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
        private readonly object _gate = new object();

        private StreamMediaFoundationReader _reader;
        private Equalizer10 _eq;
        private VolumeSampleProvider _volume;
        private WasapiOut _output;
        private RangeCachedStream _stream;          // the loaded track
        private RangeCachedStream _pendingStream;   // being opened/parsed right now
        private (string Url, RangeCachedStream Stream) _prefetched;

        private int _session;
        private bool _disposed;
        private bool _scrobbled;
        private float _linear = 1f;

        private readonly Timer _tick;

        /// <summary>Track played to its natural end (not raised by Stop/Dispose).</summary>
        public event EventHandler Ended;

        /// <summary>Decode, device, or download failure with the underlying error.</summary>
        public event EventHandler<Exception> Failed;

        /// <summary>Raised once per track at ≥50% or 4 minutes, whichever is first.</summary>
        public event EventHandler Scrobbled;

        /// <summary>4 Hz heartbeat for position/duration display. Read Position/Duration.</summary>
        public event EventHandler PlaybackTick;

        public bool IsPlaying { get; private set; }

        public TimeSpan Position => _reader?.CurrentTime ?? TimeSpan.Zero;
        public TimeSpan Duration => _reader?.TotalTime ?? TimeSpan.Zero;

        /// <summary>Cached fraction of the track, 0..1 (seek-bar buffered segment).</summary>
        public double CachedFraction => (_stream ?? _pendingStream)?.CachedFraction ?? 0;

        public AudioEngine()
        {
            _tick = new Timer(_ => OnTick(), null, 250, 250);
        }

        // ---------------- commands ----------------

        /// <summary>
        /// Load and start a track, adopting a prefetched stream when the URL
        /// matches. Replaces whatever is playing; any in-flight load is dropped.
        /// </summary>
        public async Task LoadAsync(string url)
        {
            if (_disposed) throw new ObjectDisposedException(nameof(AudioEngine));
            if (string.IsNullOrWhiteSpace(url)) throw new ArgumentException("A stream URL is required.", nameof(url));

            StopInternal();
            int session;
            lock (_gate)
            {
                session = _session;
                _scrobbled = false;
            }

            RangeCachedStream stream;
            lock (_gate)
            {
                if (_prefetched.Stream != null && _prefetched.Url == url)
                {
                    stream = _prefetched.Stream;
                    _prefetched = default;
                    PlaybackLog.Write("engine: using prefetched stream");
                }
                else
                {
                    stream = new RangeCachedStream(_http, url);
                }
                _pendingStream = stream;
            }

            try
            {
                await stream.OpenAsync().ConfigureAwait(false); // no-op on a prefetched stream
                bool committed = await Task.Run(() => SetupAndPlay(session, stream)).ConfigureAwait(false);
                if (!committed)
                {
                    ClearPending(stream);
                    stream.Dispose();
                }
            }
            catch
            {
                ClearPending(stream);
                try { stream.Dispose(); } catch { }
                throw;
            }
        }

        /// <summary>Warm the next track: open its stream and cache ~2 MB.</summary>
        public async Task PrefetchNextAsync(string url)
        {
            if (_disposed || string.IsNullOrWhiteSpace(url))
                return;

            lock (_gate)
            {
                if (_prefetched.Stream != null && _prefetched.Url == url)
                    return; // already warm
            }

            var stream = new RangeCachedStream(_http, url);
            try
            {
                await stream.OpenAsync().ConfigureAwait(false);
                await stream.WarmUpAsync(2 * 1024 * 1024).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                PlaybackLog.Write("prefetch failed: " + ex.Message);
                try { stream.Dispose(); } catch { }
                return;
            }

            RangeCachedStream old;
            lock (_gate)
            {
                if (_disposed)
                {
                    stream.Dispose();
                    return;
                }
                old = _prefetched.Stream;
                _prefetched = (url, stream);
            }
            if (old != null && !ReferenceEquals(old, stream))
                try { old.Dispose(); } catch { }
            PlaybackLog.Write($"engine: prefetched ~2 MB for next track");
        }

        public void Play()
        {
            lock (_gate)
            {
                if (_output == null || IsPlaying) return;
                _output.Play();
                IsPlaying = true;
            }
        }

        public void Pause()
        {
            lock (_gate)
            {
                if (_output == null || !IsPlaying) return;
                _output.Pause();
                IsPlaying = false;
            }
        }

        /// <summary>Jump within the track; MF seeks block, so this runs off-thread.</summary>
        public void Seek(TimeSpan position)
        {
            StreamMediaFoundationReader reader;
            lock (_gate) reader = _reader;
            if (reader == null) return;

            Task.Run(() =>
            {
                try
                {
                    reader.CurrentTime = position;
                }
                catch (ObjectDisposedException) { /* track replaced while queued */ }
                catch (Exception ex)
                {
                    Failed?.Invoke(this, ex);
                }
            });
        }

        /// <summary>Perceptual volume 0..1; the device gets v³.</summary>
        public void SetVolume(float volume01)
        {
            volume01 = Math.Clamp(volume01, 0f, 1f);
            lock (_gate)
            {
                _linear = volume01;
                if (_volume != null)
                    _volume.Volume = volume01 * volume01 * volume01;
            }
        }

        /// <summary>Set one EQ band gain in dB (index 0..9, low→high).</summary>
        public void SetEqBand(int index, float gainDb)
        {
            lock (_gate) _eq?.SetBand(index, gainDb);
        }

        public void Stop() => StopInternal();

        // ---------------- setup / teardown (worker threads) ----------------

        private bool SetupAndPlay(int session, RangeCachedStream stream)
        {
            StreamMediaFoundationReader reader = null;
            WasapiOut output = null;
            bool stale = false;

            try
            {
                lock (_gate) stale = session != _session || _disposed;
                if (stale) return false;

                reader = new StreamMediaFoundationReader(stream, new MediaFoundationReader.MediaFoundationReaderSettings());

                // MF's create-time probing leaves the source near the tail; the
                // first ReadSample would return end-of-stream instantly. Rewind.
                try { reader.CurrentTime = TimeSpan.Zero; }
                catch (Exception ex) { PlaybackLog.Write("rewind after MF create failed: " + ex.Message); }

                var eq = new Equalizer10(reader.ToSampleProvider());
                var volume = new VolumeSampleProvider(eq);
                float linear;
                lock (_gate) linear = _linear;
                volume.Volume = linear * linear * linear;

                output = new WasapiOut(AudioClientShareMode.Shared, 200);
                output.PlaybackStopped += Output_PlaybackStopped;
                output.Init(volume.ToWaveProvider());
                output.Play();

                lock (_gate)
                {
                    stale = session != _session || _disposed;
                    if (!stale)
                    {
                        _stream = stream;
                        _reader = reader;
                        _eq = eq;
                        _volume = volume;
                        _output = output;
                        _pendingStream = null;
                        IsPlaying = true;
                    }
                }

                if (stale) return false;
                PlaybackLog.Write($"engine: playing (MF reader {reader.TotalTime.TotalSeconds:F0}s, device {output.GetType().Name} initialized)");
                return true;
            }
            catch (Exception ex)
            {
                Release(output, reader);
                throw new InvalidOperationException("opening the track failed: " + FirstLine(ex.Message), ex);
            }
            finally
            {
                if (stale) Release(output, reader);
            }
        }

        private void ClearPending(RangeCachedStream stream)
        {
            lock (_gate)
            {
                if (ReferenceEquals(_pendingStream, stream))
                    _pendingStream = null;
            }
        }

        private void StopInternal()
        {
            WasapiOut output;
            StreamMediaFoundationReader reader;
            RangeCachedStream stream;

            lock (_gate)
            {
                _session++; // in-flight loads must now discard themselves
                output = _output;
                reader = _reader;
                stream = _stream;
                _output = null;
                _reader = null;
                _eq = null;
                _volume = null;
                _stream = null;
                _pendingStream = null;
                IsPlaying = false;
            }

            if (output == null) return;
            Task.Run(() => Release(output, reader, stream));
        }

        private void Release(WasapiOut output, StreamMediaFoundationReader reader, RangeCachedStream stream = null)
        {
            if (output != null)
            {
                try { output.PlaybackStopped -= Output_PlaybackStopped; } catch { }
                try { output.Stop(); } catch { }
                try { output.Dispose(); } catch { }
            }
            try { reader?.Dispose(); } catch { }
            try { stream?.Dispose(); } catch { }
        }

        private void Output_PlaybackStopped(object sender, StoppedEventArgs e)
        {
            // WasapiOut also raises this on Stop()/Dispose(); those null _output
            // first (under the gate), so a matching live reference means the
            // track ended by itself or the device failed.
            bool ours;
            lock (_gate)
            {
                ours = ReferenceEquals(sender, _output);
                if (ours) IsPlaying = false;
            }
            if (!ours) return;

            if (e.Exception != null)
            {
                Failed?.Invoke(this, e.Exception);
                return;
            }
            Ended?.Invoke(this, EventArgs.Empty);
        }

        // ---------------- 4 Hz tick ----------------

        private void OnTick()
        {
            try
            {
                if (_disposed || _reader == null)
                    return;

                var duration = Duration;
                var position = Position;

                if (!_scrobbled && duration > TimeSpan.Zero &&
                    (position >= duration * 0.5 || position >= TimeSpan.FromMinutes(4)))
                {
                    _scrobbled = true;
                    PlaybackLog.Write($"scrobble threshold reached at {position:mm\\:ss} of {duration:mm\\:ss}");
                    Scrobbled?.Invoke(this, EventArgs.Empty);
                }

                PlaybackTick?.Invoke(this, EventArgs.Empty);
            }
            catch
            {
                // A tick must never take playback down.
            }
        }

        private static string FirstLine(string message)
        {
            if (string.IsNullOrWhiteSpace(message))
                return "Unknown error.";
            var msg = message.Trim();
            int cut = msg.IndexOfAny(new[] { '\r', '\n' });
            return cut > 0 ? msg.Substring(0, cut) : msg;
        }

        public void Dispose()
        {
            lock (_gate)
            {
                if (_disposed) return;
                _disposed = true;
            }
            _tick.Dispose();
            StopInternal();

            RangeCachedStream prefetched;
            lock (_gate)
            {
                prefetched = _prefetched.Stream;
                _prefetched = default;
            }
            try { prefetched?.Dispose(); } catch { }
            _http.Dispose();
        }
    }
}
