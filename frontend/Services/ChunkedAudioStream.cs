using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace YtMusicClient.Services
{
    /// <summary>
    /// Seekable audio source that plays from whatever has arrived so far instead
    /// of waiting for a whole track to download.
    ///
    /// One long-lived GET streams the file front-to-back into an in-memory buffer
    /// on a background task; reads block only until the bytes they need have
    /// landed, so the first seconds of audio play while the rest keeps filling in.
    ///
    /// Reads that jump FAR ahead of the download — Media Foundation's open-time
    /// probe reads the last ~256 KB of the file, and so does a far user seek —
    /// cannot be served by that front-to-back flow in useful time: they used to
    /// block until the WHOLE track had arrived, so playback only started after the
    /// full download (measured: a 113 s wait on a 3.9 MB track). Such reads are
    /// now served by a small, bounded number of extra ranged GETs on the same
    /// signed URL (see FarReadGapBytes / MaxFarFills); when the CDN refuses
    /// ranges, the read falls back to waiting on the main download — the old
    /// behaviour, correct just slower.
    /// </summary>
    public sealed class ChunkedAudioStream : Stream
    {
        // No new bytes for this long while someone is waiting on them means the
        // connection went silent — fail with a readable error instead of waiting
        // forever (an eternal wait is what hung Media Foundation, and with it
        // the app, when the parse ran on the UI thread). 60s, not 3s: this app's
        // users can be on cellular links that go silent for half a minute
        // mid-transfer and then resume, and a false "stalled" kills the track.
        private const int StallTimeoutMs = 60_000;

        // When only this many bytes are still missing and the download stalls,
        // serve what we have as a clean EOF instead of failing: Media Foundation
        // opens a truncated MP4 fine (duration comes from the front-loaded moov),
        // and on a slow connection the withheld tail used to turn into a hard
        // "Catastrophic failure" from the decoder.
        private const long TailGraceBytes = 512 * 1024;

        // A read this far beyond the download front is a jump (MF's open-time tail
        // probe, or a far seek), not sequential decode. Serve its window from a
        // ranged GET instead of stalling the decoder until the pump crawls there.
        private const long FarReadGapBytes = 2 * 1024 * 1024;

        // Upper bound on those extra ranged requests per track — extra requests on
        // a signed googlevideo URL are the one thing the CDN is known to punish
        // with 403, so the budget stays small. MF's open needs one or two; beyond
        // the budget, reads fall back to waiting on the main download.
        private const int MaxFarFills = 8;

        // Bound for one ranged window fetch; a slow CDN must fall back to the main
        // download rather than hold the decoder for minutes.
        private const int FarFillTimeoutSeconds = 20;

        // Bounded diagnostic trace of what Media Foundation actually asks this
        // stream for (seeks, slow reads, EOFs). Only the first events are kept —
        // enough to see the exact read sequence when MFCreate fails.
        private const int MaxTraceEvents = 240;
        private int _traceCount;

        private void Trace(string message)
        {
            if (Interlocked.Increment(ref _traceCount) <= MaxTraceEvents)
                PlaybackLog.Write("stream: " + message);
        }

        private readonly HttpClient _http;
        private readonly CancellationTokenSource _cts = new CancellationTokenSource();
        private readonly object _gate = new object();

        private byte[] _buffer;
        private long _length;
        private long _downloaded;
        private long _position;
        private long _lastProgressTick; // Environment.TickCount64 of the last byte
        private bool _pumpCompleted;
        private bool _elstScanDone;     // moov edit lists handled (or nothing to do)
        private Exception _pumpError;
        private Task _pump;

        // Windows already fetched by ranged GETs (bounded by MaxFarFills). The main
        // pump later re-downloads and overwrites these regions with identical
        // bytes — harmless — but until then this is what makes the bytes servable,
        // because _downloaded only tracks the front-to-back pump.
        private readonly List<(long From, long To)> _farFilledRanges = new List<(long From, long To)>();
        private int _farFills;

        private HttpResponseMessage _response;
        private Stream _network;

        /// <param name="http">Shared client; must allow auto-redirect.</param>
        /// <param name="url">Signed googlevideo URL resolved by the backend.</param>
        public ChunkedAudioStream(HttpClient http, string url)
        {
            _http = http ?? throw new ArgumentNullException(nameof(http));
            _url = url ?? throw new ArgumentNullException(nameof(url));
        }

        private string _url { get; }

        /// <summary>
        /// Opens the connection and learns the track length. Must be awaited
        /// before handing the stream to NAudio.
        /// </summary>
        public async Task OpenAsync()
        {
            _lastProgressTick = Environment.TickCount64;

            // ResponseHeadersRead returns as soon as headers are in, so the body
            // can start flowing to the buffer while we set everything else up.
            // The HttpClient timeout is infinite (it covers whole-track reads),
            // so the wait for headers needs its own bound: a CDN that accepts the
            // connection and then goes silent must fail, not hang the load.
            using var headerTimeout = CancellationTokenSource.CreateLinkedTokenSource(_cts.Token);
            headerTimeout.CancelAfter(TimeSpan.FromSeconds(30));
            try
            {
                _response = await _http
                    .GetAsync(_url, HttpCompletionOption.ResponseHeadersRead, headerTimeout.Token)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!_cts.IsCancellationRequested)
            {
                throw new TimeoutException(
                    "The audio server did not send a response within 30 seconds.");
            }
            _response.EnsureSuccessStatusCode();

            long length = _response.Content.Headers.ContentLength ?? 0;
            if (length <= 0)
            {
                _response.Dispose();
                throw new InvalidDataException(
                    "The stream did not report a Content-Length, so progressive playback cannot size its buffer.");
            }

            _length = length;
            _buffer = new byte[length];
            _network = await _response.Content.ReadAsStreamAsync(_cts.Token).ConfigureAwait(false);
            _pump = Task.Run(PumpAsync);

            string host = "?";
            try { host = new Uri(_url).Host; } catch (UriFormatException) { }
            PlaybackLog.Write($"stream opened from {host}: expecting {length:N0} bytes");
        }

        private async Task PumpAsync()
        {
            try
            {
                while (_downloaded < _length)
                {
                    int read = await _network
                        .ReadAsync(_buffer.AsMemory((int)_downloaded, (int)(_length - _downloaded)), _cts.Token)
                        .ConfigureAwait(false);

                    if (read <= 0)
                        break; // connection ended early; playback stops at what we have

                    lock (_gate)
                    {
                        _downloaded += read;

                        // Before Media Foundation can observe them, neutralize any
                        // edit lists in moov — MF's fragmented-MP4 reader treats
                        // their media_time priming as "start past the samples" and
                        // returns end-of-stream on the very first decode (the
                        // "plays for 28 ms then ends" bug). Runs in the same
                        // critical section that publishes the bytes, so a reader
                        // can never see an unpatched elst.
                        NeutralizeMoovEditListsLocked();

                        _lastProgressTick = Environment.TickCount64;
                        Monitor.PulseAll(_gate);
                    }
                }
            }
            catch (OperationCanceledException)
            {
                // Shutting down; not an error.
            }
            catch (Exception ex)
            {
                lock (_gate) _pumpError = ex;
                PlaybackLog.Write("download error: " + ex);
            }
            finally
            {
                long done;
                Exception error;
                lock (_gate)
                {
                    _pumpCompleted = true;
                    Monitor.PulseAll(_gate);
                    done = _downloaded;
                    error = _pumpError;
                }

                // Distinguishes a clean full download from an early close — the
                // difference between "worked" and a baffling MF parse failure.
                PlaybackLog.Write(error == null
                    ? $"download finished: {done:N0} of {_length:N0} bytes"
                    : $"download stopped after {done:N0} of {_length:N0} bytes");
            }
        }

        public override bool CanRead => true;
        public override bool CanSeek => true;
        public override bool CanWrite => false;
        public override long Length => Interlocked.Read(ref _length);

        public override long Position
        {
            get => Interlocked.Read(ref _position);
            set => Seek(value, SeekOrigin.Begin);
        }

        public override long Seek(long offset, SeekOrigin origin)
        {
            long target = origin switch
            {
                SeekOrigin.Begin => offset,
                SeekOrigin.Current => _position + offset,
                SeekOrigin.End => _length + offset,
                _ => throw new ArgumentOutOfRangeException(nameof(origin)),
            };

            // Positions are logical, not "whatever has downloaded": Media Foundation
            // probes the source with Seek(End) to learn the track length, and handing
            // back a clamped value made it see a zero-byte file and fail with
            // E_UNEXPECTED. Read() blocks until the bytes at a forward position have
            // actually arrived, so seeking ahead stays correct — it just waits for
            // the download to catch up, which is the point of progressive loading.
            long requested = target;
            if (target < 0) target = 0;
            if (target > _length) target = _length;

            Trace($"Seek({origin}, {offset}) requested={requested} -> {target} (downloaded={Interlocked.Read(ref _downloaded)})");

            Interlocked.Exchange(ref _position, target);
            return target;
        }

        /// <summary>Bytes received so far — the UI can show download progress.</summary>
        public long BufferedLength
        {
            get { lock (_gate) return _downloaded; }
        }

        /// <summary>The failure that stopped the background download, if any.</summary>
        public Exception PumpError
        {
            get { lock (_gate) return _pumpError; }
        }

        /// <summary>
        /// True when every expected byte arrived. When Media Foundation rejects
        /// the stream and this is false, the download — not the decoder — is what
        /// actually went wrong.
        /// </summary>
        public bool DownloadComplete
        {
            get { lock (_gate) return _pumpCompleted && _downloaded >= _length && _pumpError == null; }
        }

        public override int Read(byte[] buffer, int offset, int count)
        {
            if (buffer == null) throw new ArgumentNullException(nameof(buffer));
            if (offset < 0 || count < 0 || offset + count > buffer.Length)
                throw new ArgumentOutOfRangeException(nameof(count));

            if (count == 0) return 0;

            long started = Environment.TickCount64;

            while (true)
            {
                long farFrom = -1, farCount = 0;
                Exception error = null;
                lock (_gate)
                {
                    long pos = _position;
                    if (pos >= _length)
                    {
                        Trace($"Read at {pos} >= length {_length} -> EOF (waited {Environment.TickCount64 - started}ms)");
                        return 0;
                    }

                    // Satisfy the WHOLE request before returning, like a file
                    // stream would. Handing MF a short read the instant a few
                    // bytes exist made it reject the file ("Catastrophic
                    // failure") whenever the tail arrived late — the tail read
                    // only completes properly once the buffer has everything up
                    // to pos+count or the download genuinely ends.
                    long needed = Math.Min(pos + count, _length);

                    if (_downloaded >= needed || IsFarFilledLocked(pos, needed))
                    {
                        int available = (int)(needed - pos);
                        Buffer.BlockCopy(_buffer, (int)pos, buffer, offset, available);
                        _position = pos + available;
                        long waited = Environment.TickCount64 - started;
                        if (waited > 500)
                            Trace($"Read {available} bytes at {pos} after waiting {waited}ms (downloaded={_downloaded})");
                        return available;
                    }

                    if (_pumpCompleted)
                    {
                        // Download over. Deliver what arrived (a short read IS
                        // legal at true EOF), surface the failure that stopped
                        // the pump, or report a clean end — never swallow.
                        error = _pumpError;
                        if (error == null)
                        {
                            if (_downloaded > pos)
                            {
                                int available = (int)(_downloaded - pos);
                                Buffer.BlockCopy(_buffer, (int)pos, buffer, offset, available);
                                _position = pos + available;
                                Trace($"Read {available} bytes at {pos} at true EOF (download ended at {_downloaded})");
                                return available;
                            }
                            Trace($"Read at {pos} but download ended at {_downloaded} -> EOF (waited {Environment.TickCount64 - started}ms)");
                            return 0;
                        }
                    }

                    if (error == null)
                    {
                        // Stall guard: the pump is alive but nothing has arrived
                        // for a long time (silent connection). Fail loudly rather
                        // than block the caller — and whoever called us — forever.
                        if (Environment.TickCount64 - _lastProgressTick > StallTimeoutMs)
                        {
                            long missing = _length - _downloaded;
                            if (missing > 0 && missing <= TailGraceBytes)
                            {
                                PlaybackLog.Write(
                                    $"tail stalled: serving early EOF with {_downloaded:N0} of {_length:N0} bytes");
                                return 0;
                            }

                            error = new IOException(
                                $"The audio download stalled: no data received for {StallTimeoutMs / 1000} seconds " +
                                $"({missing:N0} bytes still missing).");
                            // Media Foundation will swallow this into a generic
                            // 0x8000FFFF — the real reason must exist somewhere.
                            PlaybackLog.Write("read stalled: " + error.Message);
                        }
                        else if (pos > _downloaded + FarReadGapBytes && _farFills < MaxFarFills)
                        {
                            // Jump read (tail probe / far seek): leave the lock and
                            // fetch the window directly instead of waiting for the
                            // pump to traverse everything in between.
                            farFrom = pos;
                            farCount = needed - pos;
                        }
                        else
                        {
                            // Wait for the next chunk to land.
                            Monitor.Wait(_gate, 1000);
                            continue;
                        }
                    }
                }

                if (error != null)
                    throw new IOException("Audio download failed before the track finished.", error);

                if (farFrom >= 0)
                {
                    if (FarFill(farFrom, farCount))
                        continue; // window is in the buffer; the loop serves it now

                    // Ranges refused or failed — wait on the main download (old behaviour).
                    lock (_gate) Monitor.Wait(_gate, 1000);
                }
            }
        }

        /// <summary>True when [from, to) was already fetched by a ranged GET. Caller holds _gate.</summary>
        private bool IsFarFilledLocked(long from, long to)
        {
            for (int i = 0; i < _farFilledRanges.Count; i++)
            {
                if (_farFilledRanges[i].From <= from && to <= _farFilledRanges[i].To)
                    return true;
            }
            return false;
        }

        /// <summary>
        /// Fetches [from, from+count) with one bounded ranged request and copies it
        /// into the buffer. Runs OUTSIDE _gate — the main pump keeps flowing while
        /// this waits on the network. Returns false (leaving the read to the main
        /// pump) when the server refuses ranges, returns the wrong window, the
        /// window cannot be filled completely, or the request fails/times out.
        /// </summary>
        private bool FarFill(long from, long count)
        {
            Trace($"far read at {from:N0} ({count:N0} bytes; main pump at {Interlocked.Read(ref _downloaded):N0}) — fetching a ranged window directly");
            try
            {
                using var request = new HttpRequestMessage(HttpMethod.Get, _url);
                request.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(from, from + count - 1);

                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(_cts.Token);
                timeout.CancelAfter(TimeSpan.FromSeconds(FarFillTimeoutSeconds));

                using var response = _http
                    .SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token)
                    .GetAwaiter().GetResult();

                // A 200 means the CDN ignored the Range and is streaming the whole
                // file from byte 0 — useless for a window at `from`, and reading it
                // would mean downloading the track twice.
                if (response.StatusCode != System.Net.HttpStatusCode.PartialContent)
                {
                    PlaybackLog.Write($"far fill at {from:N0}: server returned {response.StatusCode}, not 206 — falling back to the main download");
                    return false;
                }

                var contentRange = response.Content.Headers.ContentRange;
                if (contentRange?.From != null && contentRange.From.Value != from)
                {
                    PlaybackLog.Write($"far fill at {from:N0}: server answered with the wrong window (from {contentRange.From.Value}) — falling back to the main download");
                    return false;
                }

                var window = new byte[count];
                long filled = 0;
                using var body = response.Content.ReadAsStream(timeout.Token);
                while (filled < count)
                {
                    int n = body.Read(window, (int)filled, (int)(count - filled));
                    if (n <= 0) break;
                    filled += n;
                }

                if (filled < count)
                {
                    PlaybackLog.Write($"far fill at {from:N0}: only {filled:N0} of {count:N0} bytes arrived — falling back to the main download");
                    return false;
                }

                int nth;
                lock (_gate)
                {
                    Buffer.BlockCopy(window, 0, _buffer, (int)from, (int)filled);
                    _farFilledRanges.Add((from, from + filled));
                    nth = ++_farFills;
                    Monitor.PulseAll(_gate);
                }

                PlaybackLog.Write(
                    $"far fill: fetched {filled:N0} bytes at {from:N0} directly " +
                    $"({nth}/{MaxFarFills} ranged requests; main pump still at {Interlocked.Read(ref _downloaded):N0})");
                return true;
            }
            catch (OperationCanceledException) when (!_cts.IsCancellationRequested)
            {
                PlaybackLog.Write($"far fill at {from:N0} timed out — falling back to the main download");
                return false;
            }
            catch (Exception ex)
            {
                PlaybackLog.Write($"far fill at {from:N0} failed: {ex.Message} — falling back to the main download");
                return false;
            }
        }

        public override void Flush() { }

        // ---------------- moov edit-list workaround ----------------

        // Must be called with _gate held. Walks top-level boxes as they become
        // fully buffered; once moov is available, rewrites every elst fourcc
        // inside it to "free" (same size — a no-op for any parser, invisible to
        // readers that already passed this point because the patch happens in the
        // same critical section that publishes the bytes).
        private void NeutralizeMoovEditListsLocked()
        {
            if (_elstScanDone || _downloaded < 32)
                return;

            long pos = 0;
            while (pos + 8 <= _downloaded)
            {
                uint boxSize = ReadUInt32BE(pos);
                string boxType = ReadFourCC(pos + 4);

                if (boxSize == 1)
                {
                    // 64-bit size — not expected for moov on these streams; stop
                    // scanning rather than misparse.
                    _elstScanDone = true;
                    return;
                }
                if (boxSize == 0)
                    boxSize = (uint)Math.Min(_length, int.MaxValue); // box extends to EOF
                if (boxSize < 8)
                {
                    _elstScanDone = true; // corrupt layout; nothing to patch
                    return;
                }

                if (boxType == "moov")
                {
                    if (pos + boxSize > _downloaded)
                        return; // moov not fully here yet — retry after next chunk

                    int patched = PatchEditLists(pos + 8, pos + boxSize);
                    if (patched > 0)
                        PlaybackLog.Write(
                            $"neutralized {patched} moov edit list(s) (MF workaround for instant end-of-stream)");
                    _elstScanDone = true;
                    return;
                }

                if (pos + boxSize > _downloaded)
                    return; // can't advance past an incomplete box — retry later
                pos += boxSize;
            }
            // Need more bytes to see the next top-level box.
        }

        /// <summary>Rewrites elst fourccs to free inside [start, end). Caller holds _gate.</summary>
        private int PatchEditLists(long start, long end)
        {
            int patched = 0;
            long limit = Math.Min(end - 12, _downloaded - 4);
            for (long i = start; i <= limit; i++)
            {
                if (_buffer[i] != (byte)'e' || _buffer[i + 1] != (byte)'l' ||
                    _buffer[i + 2] != (byte)'s' || _buffer[i + 3] != (byte)'t')
                    continue;

                long boxStart = i - 4;
                if (boxStart < start)
                    continue;
                uint boxSize = ReadUInt32BE(boxStart);
                if (boxSize < 16 || boxStart + boxSize > end)
                    continue; // not a real box header — just bytes that spell "elst"

                _buffer[i] = (byte)'f';
                _buffer[i + 1] = (byte)'r';
                _buffer[i + 2] = (byte)'e';
                _buffer[i + 3] = (byte)'e';
                patched++;
                i += 3;
            }
            return patched;
        }

        private uint ReadUInt32BE(long pos) =>
            ((uint)_buffer[pos] << 24) | ((uint)_buffer[pos + 1] << 16) |
            ((uint)_buffer[pos + 2] << 8) | _buffer[pos + 3];

        private string ReadFourCC(long pos) =>
            new string(new[]
            {
                (char)_buffer[pos], (char)_buffer[pos + 1],
                (char)_buffer[pos + 2], (char)_buffer[pos + 3],
            });

        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                try { _cts.Cancel(); } catch (ObjectDisposedException) { }
                try { _network?.Dispose(); } catch { }
                try { _response?.Dispose(); } catch { }
                try { _pump?.Wait(2000); } catch { }
                _cts.Dispose();
            }
            base.Dispose(disposing);
        }
    }
}
