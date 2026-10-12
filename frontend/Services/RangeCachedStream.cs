using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace YtMusicClient.Services
{
    /// <summary>
    /// Seekable audio source backed by a sparse on-disk cache of fixed 256 KB
    /// ranges: an HTTP source, a range index of what is already on disk, and a
    /// background pump that keeps roughly 3 MB ahead of the playhead. Reads
    /// block only on uncached ranges, played ranges are never re-downloaded
    /// (the index persists across app runs), and a track of any length costs
    /// only the disk it has actually played — never a whole-file RAM buffer.
    ///
    /// When the CDN refuses Range requests (200 instead of 206), the stream
    /// degrades to the old sequential behaviour: one long download fills the
    /// cache front-to-back and far seeks wait on it. Real googlevideo URLs
    /// support ranges (verified: 206 + ranged windows), so that path is a
    /// defensive fallback only.
    /// </summary>
    public sealed class RangeCachedStream : Stream
    {
        public const int ChunkSize = 256 * 1024;

        private const int PrefetchChunksAhead = 12;  // ~3 MB ahead of the playhead
        private const int StallTimeoutMs = 60_000;   // silent connection guard
        private const long FrontPatchBytes = 2 * 1024 * 1024; // moov/elst region

        private readonly HttpClient _http;
        private readonly string _url;
        private readonly CancellationTokenSource _cts = new();

        private readonly object _gate = new();
        private readonly HashSet<int> _cached = new();

        private FileStream _cache;            // single handle: reads AND writes seek under _gate
        private long _length;
        private int _chunkCount;
        private long _playhead;               // Interlocked
        private long _lastProgressTick;
        private bool _rangesSupported = true;
        private bool _elstScanDone;
        private bool _pumpDone;
        private Exception _pumpError;
        private HttpResponseMessage _response;
        private Stream _network;              // sequential body (ranges unsupported only)
        private Task _pump;
        private string _idxPath;

        /// <summary>True once the connection is open and the length is known.</summary>
        public bool IsOpen { get; private set; }

        /// <summary>Cached fraction of the whole track, 0..1 (for the seek-bar segment).</summary>
        public double CachedFraction
        {
            get
            {
                lock (_gate)
                    return _chunkCount == 0 ? 0 : Math.Clamp((double)_cached.Count / _chunkCount, 0, 1);
            }
        }

        /// <summary>The failure that stopped the sequential pump, if any.</summary>
        public Exception PumpError { get { lock (_gate) return _pumpError; } }

        public RangeCachedStream(HttpClient http, string url)
        {
            _http = http ?? throw new ArgumentNullException(nameof(http));
            _url = url ?? throw new ArgumentNullException(nameof(url));
        }

        // ---------------- open ----------------

        /// <summary>
        /// Opens the connection, learns the track length, and starts the
        /// prefetch pump. Must be awaited before handing the stream to the
        /// decoder. Idempotent: a prefetched stream is already open.
        /// </summary>
        public async Task OpenAsync()
        {
            if (IsOpen)
                return;
            _lastProgressTick = Environment.TickCount64;

            string dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "YtMusicClient", "AudioCache");
            Directory.CreateDirectory(dir);
            string baseName = Path.Combine(dir, Sha1Hex(_url));
            string dataPath = baseName + ".cache";
            _idxPath = baseName + ".idx";

            // One ranged GET doubles as the length probe and chunk 0.
            using var headerTimeout = CancellationTokenSource.CreateLinkedTokenSource(_cts.Token);
            headerTimeout.CancelAfter(TimeSpan.FromSeconds(30));
            var probe = new HttpRequestMessage(HttpMethod.Get, _url);
            probe.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(0, ChunkSize - 1);
            _response = await _http
                .SendAsync(probe, HttpCompletionOption.ResponseHeadersRead, headerTimeout.Token)
                .ConfigureAwait(false);

            _cache = new FileStream(dataPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.Read);

            if (_response.StatusCode == System.Net.HttpStatusCode.PartialContent)
            {
                var contentRange = _response.Content.Headers.ContentRange;
                if (contentRange?.Length is not long len || len <= 0)
                {
                    await CleanupFailedOpenAsync().ConfigureAwait(false);
                    throw new InvalidDataException("The audio server did not report the track length.");
                }
                _length = len;
                _rangesSupported = true;
            }
            else if (_response.StatusCode == System.Net.HttpStatusCode.OK)
            {
                long? cl = _response.Content.Headers.ContentLength;
                if (cl is not long len2 || len2 <= 0)
                {
                    await CleanupFailedOpenAsync().ConfigureAwait(false);
                    throw new InvalidDataException("The audio server did not report a Content-Length.");
                }
                _length = len2;
                _rangesSupported = false;
                _network = await _response.Content.ReadAsStreamAsync(_cts.Token).ConfigureAwait(false);
            }
            else
            {
                var code = _response.StatusCode;
                await CleanupFailedOpenAsync().ConfigureAwait(false);
                throw new HttpRequestException($"The audio server returned {(int)code} ({code}).");
            }

            _cache.SetLength(_length);
            _chunkCount = (int)((_length + ChunkSize - 1) / ChunkSize);
            LoadIndex(dataPath);

            if (_rangesSupported)
            {
                // The probe body IS chunk 0 — write it instead of re-fetching.
                var first = new byte[ChunkSize];
                int got = 0;
                using (var body = await _response.Content.ReadAsStreamAsync(headerTimeout.Token).ConfigureAwait(false))
                {
                    while (got < ChunkSize)
                    {
                        int n = await body.ReadAsync(first.AsMemory(got, ChunkSize - got), headerTimeout.Token).ConfigureAwait(false);
                        if (n <= 0) break;
                        got += n;
                    }
                }
                if (got > 0)
                    WriteChunk(0, first, got);
            }

            IsOpen = true;
            PlaybackLog.Write($"range cache open: {_length:N0} bytes, {_chunkCount} chunks, " +
                              $"{_cached.Count} already cached, ranges {(_rangesSupported ? "ok" : "UNSUPPORTED")}, " +
                              $"first 256KB probe done (chunk 0 on disk = first bytes ready for MF)");
            _pump = Task.Run(_rangesSupported ? PrefetchPumpAsync : SequentialPumpAsync);
        }

        private async Task CleanupFailedOpenAsync()
        {
            try { _response?.Dispose(); } catch { }
            try { _cache?.Dispose(); } catch { }
            _cache = null;
            await Task.CompletedTask;
        }

        private void LoadIndex(string dataPath)
        {
            try
            {
                if (!File.Exists(_idxPath))
                    return;
                var lines = File.ReadAllLines(_idxPath);
                if (lines.Length < 2 || !long.TryParse(lines[0], out long savedLength) || savedLength != _length)
                {
                    File.Delete(_idxPath); // stale index for a different encoding — re-cache
                    return;
                }
                foreach (var part in lines[1].Split(',', StringSplitOptions.RemoveEmptyEntries))
                    if (int.TryParse(part, out int c) && c >= 0 && c < _chunkCount)
                        _cached.Add(c);
            }
            catch (Exception ex)
            {
                PlaybackLog.Write("cache index load failed (starting fresh): " + ex.Message);
            }
        }

        private void SaveIndex()
        {
            try
            {
                string indices = string.Join(",", _cached);
                File.WriteAllText(_idxPath, $"{_length}\n{indices}");
            }
            catch { /* a lost index only costs a re-download */ }
        }

        // ---------------- caching ----------------

        /// <summary>Writes one chunk to the cache file and marks it present.</summary>
        private void WriteChunk(int chunk, byte[] buf, int count)
        {
            long from = (long)chunk * ChunkSize;
            lock (_gate)
            {
                _cache.Seek(from, SeekOrigin.Begin);
                _cache.Write(buf, 0, count);
                _cache.Flush();
                _cached.Add(chunk);
                _lastProgressTick = Environment.TickCount64;
                Monitor.PulseAll(_gate);
            }
            SaveIndex();
        }

        /// <summary>
        /// Background pump: keep chunks [playhead, playhead + ahead) on disk.
        /// Sequential awaits — one fetch at a time, no single-flight bookkeeping.
        /// </summary>
        private async Task PrefetchPumpAsync()
        {
            try
            {
                while (!_cts.IsCancellationRequested)
                {
                    int head;
                    lock (_gate) head = (int)(Interlocked.Read(ref _playhead) / ChunkSize);

                    for (int k = head; k <= head + PrefetchChunksAhead && k < _chunkCount; k++)
                    {
                        bool have;
                        lock (_gate) have = _cached.Contains(k);
                        if (have)
                            continue;
                        bool ok = await FetchChunkAsync(k).ConfigureAwait(false);
                        if (!ok)
                            break; // CDN refused this window — retry on the next tick
                    }

                    await Task.Delay(100, _cts.Token).ConfigureAwait(false);
                }
            }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                PlaybackLog.Write("prefetch pump error: " + ex);
            }
        }

        /// <summary>Defensive path for servers that ignore Range: fill front-to-back.</summary>
        private async Task SequentialPumpAsync()
        {
            var accum = new byte[ChunkSize];
            int filled = 0;
            long chunkIndex = 0;
            try
            {
                while (!_cts.IsCancellationRequested)
                {
                    int n = await _network
                        .ReadAsync(accum.AsMemory(filled, ChunkSize - filled), _cts.Token)
                        .ConfigureAwait(false);
                    if (n <= 0)
                        break;
                    filled += n;
                    if (filled == ChunkSize)
                    {
                        WriteChunk((int)chunkIndex, accum, filled);
                        chunkIndex++;
                        filled = 0;
                    }
                }
                if (filled > 0 && chunkIndex < _chunkCount)
                    WriteChunk((int)chunkIndex, accum, filled);
                PlaybackLog.Write($"sequential download finished at chunk {chunkIndex}");
            }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                lock (_gate) { _pumpError = ex; _pumpDone = true; Monitor.PulseAll(_gate); }
                PlaybackLog.Write("sequential download error: " + ex);
            }
            finally
            {
                lock (_gate) { _pumpDone = true; Monitor.PulseAll(_gate); }
            }
        }

        private async Task<bool> FetchChunkAsync(int chunk)
        {
            try
            {
                long from = (long)chunk * ChunkSize;
                int size = (int)Math.Min(ChunkSize, _length - from);
                using var req = new HttpRequestMessage(HttpMethod.Get, _url);
                req.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(from, from + size - 1);
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(_cts.Token);
                timeout.CancelAfter(TimeSpan.FromSeconds(30));
                using var resp = await _http
                    .SendAsync(req, HttpCompletionOption.ResponseHeadersRead, timeout.Token)
                    .ConfigureAwait(false);

                if (resp.StatusCode != System.Net.HttpStatusCode.PartialContent)
                {
                    PlaybackLog.Write($"chunk {chunk}: server returned {resp.StatusCode}, not 206");
                    return false;
                }
                var contentRange = resp.Content.Headers.ContentRange;
                if (contentRange?.From != null && contentRange.From.Value != from)
                {
                    PlaybackLog.Write($"chunk {chunk}: server answered with the wrong window");
                    return false;
                }

                var buf = new byte[size];
                int got = 0;
                using (var body = await resp.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false))
                {
                    while (got < size)
                    {
                        int n = await body.ReadAsync(buf.AsMemory(got, size - got), timeout.Token).ConfigureAwait(false);
                        if (n <= 0) break;
                        got += n;
                    }
                }
                if (got < size)
                {
                    PlaybackLog.Write($"chunk {chunk}: only {got:N0} of {size:N0} bytes arrived");
                    return false;
                }

                WriteChunk(chunk, buf, got);
                if ((long)chunk * ChunkSize < FrontPatchBytes)
                    TryPatchFront();
                return true;
            }
            catch (OperationCanceledException) when (!_cts.IsCancellationRequested)
            {
                PlaybackLog.Write($"chunk {chunk} fetch timed out");
                return false;
            }
            catch (Exception ex)
            {
                PlaybackLog.Write($"chunk {chunk} fetch failed: {ex.Message}");
                return false;
            }
        }

        /// <summary>Preload the first `bytes` of the track (used for next-track prefetch).</summary>
        public async Task WarmUpAsync(int bytes)
        {
            if (!IsOpen)
                throw new InvalidOperationException("OpenAsync must complete before WarmUpAsync.");
            int chunks = (int)Math.Min((bytes + ChunkSize - 1) / ChunkSize, (long)_chunkCount);
            for (int c = 0; c < chunks; c++)
            {
                bool have;
                lock (_gate) have = _cached.Contains(c);
                if (!have)
                    await FetchChunkAsync(c).ConfigureAwait(false);
            }
        }

        // ---------------- moov edit-list workaround ----------------

        // Media Foundation's reader treats moov edit-list priming as
        // "start past the samples" and ends playback after ~28 ms. The fix is
        // to rewrite the elst fourccs to "free" before the decoder sees them.
        // Runs over the cached front region as soon as it is fully on disk;
        // the patched four bytes are written back to the cache file. Ceiling:
        // assumes moov lives in the first 2 MB (true for googlevideo streams).
        private void TryPatchFront()
        {
            lock (_gate)
            {
                if (_elstScanDone)
                    return;

                long scanEnd = Math.Min(FrontPatchBytes, _length);
                int neededChunks = (int)((scanEnd + ChunkSize - 1) / ChunkSize);
                for (int c = 0; c < neededChunks; c++)
                    if (!_cached.Contains(c))
                        return; // front region not fully cached yet — retry after next chunk

                var buf = new byte[scanEnd];
                _cache.Seek(0, SeekOrigin.Begin);
                int read = 0;
                while (read < scanEnd)
                {
                    int n = _cache.Read(buf, read, (int)(scanEnd - read));
                    if (n <= 0) return;
                    read += n;
                }

                // Walk top-level boxes from 0 (port of the proven ChunkedAudioStream logic).
                long pos = 0;
                while (pos + 8 <= read)
                {
                    uint boxSize = ReadUInt32BE(buf, pos);
                    string boxType = ReadFourCC(buf, pos + 4);

                    if (boxSize == 1) { _elstScanDone = true; return; } // 64-bit size: not expected
                    if (boxSize == 0)
                        boxSize = (uint)Math.Min(_length, int.MaxValue);
                    if (boxSize < 8) { _elstScanDone = true; return; }  // corrupt layout

                    if (boxType == "moov")
                    {
                        if (pos + boxSize > read)
                            return; // moov not fully cached yet — retry after next chunk
                        int patched = PatchEditLists(buf, pos + 8, pos + boxSize);
                        if (patched > 0)
                        {
                            _cache.Seek(pos + 8, SeekOrigin.Begin);
                            _cache.Write(buf, (int)(pos + 8), (int)Math.Min(boxSize - 8, read - (pos + 8)));
                            _cache.Flush();
                            PlaybackLog.Write($"neutralized {patched} moov edit list(s) in the disk cache (MF 28 ms workaround)");
                        }
                        _elstScanDone = true;
                        return;
                    }

                    if (pos + boxSize > read)
                        return; // can't advance past an incomplete box — retry later
                    pos += boxSize;
                }
                // Need more bytes to see the next top-level box.
            }
        }

        private static int PatchEditLists(byte[] buf, long start, long end)
        {
            int patched = 0;
            long limit = Math.Min(end - 12, buf.Length - 4);
            for (long i = start; i <= limit; i++)
            {
                if (buf[i] != (byte)'e' || buf[i + 1] != (byte)'l' ||
                    buf[i + 2] != (byte)'s' || buf[i + 3] != (byte)'t')
                    continue;
                long boxStart = i - 4;
                if (boxStart < start)
                    continue;
                uint boxSize = ReadUInt32BE(buf, boxStart);
                if (boxSize < 16 || boxStart + boxSize > end)
                    continue; // not a real box header — just bytes that spell "elst"

                buf[i] = (byte)'f';
                buf[i + 1] = (byte)'r';
                buf[i + 2] = (byte)'e';
                buf[i + 3] = (byte)'e';
                patched++;
                i += 3;
            }
            return patched;
        }

        private static uint ReadUInt32BE(byte[] buf, long pos) =>
            ((uint)buf[pos] << 24) | ((uint)buf[pos + 1] << 16) |
            ((uint)buf[pos + 2] << 8) | buf[pos + 3];

        private static string ReadFourCC(byte[] buf, long pos) =>
            new string(new[] { (char)buf[pos], (char)buf[pos + 1], (char)buf[pos + 2], (char)buf[pos + 3] });

        // ---------------- Stream surface ----------------

        public override bool CanRead => true;
        public override bool CanSeek => true;
        public override bool CanWrite => false;

        public override long Length => Interlocked.Read(ref _length);

        public override long Position
        {
            get => Interlocked.Read(ref _playhead);
            set => Seek(value, SeekOrigin.Begin);
        }

        public override long Seek(long offset, SeekOrigin origin)
        {
            long target = origin switch
            {
                SeekOrigin.Begin => offset,
                SeekOrigin.Current => Interlocked.Read(ref _playhead) + offset,
                SeekOrigin.End => _length + offset,
                _ => throw new ArgumentOutOfRangeException(nameof(origin)),
            };
            long requested = target;
            if (target < 0) target = 0;
            if (target > _length) target = _length;

            if (Math.Abs(target - Interlocked.Read(ref _playhead)) > ChunkSize)
                PlaybackLog.Write($"range cache seek: {requested:N0} -> {target:N0}");
            Interlocked.Exchange(ref _playhead, target);
            return target;
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
                lock (_gate)
                {
                    long pos = Interlocked.Read(ref _playhead);
                    if (pos >= _length)
                        return 0;

                    long need = Math.Min(pos + count, _length);
                    int firstChunk = (int)(pos / ChunkSize);
                    int lastChunk = (int)((need - 1) / ChunkSize);

                    bool allCached = true;
                    for (int c = firstChunk; c <= lastChunk; c++)
                        if (!_cached.Contains(c)) { allCached = false; break; }

                    if (!allCached && _pumpDone)
                    {
                        // The fill pump ended (error or early close) before this range.
                        if (_pumpError != null)
                            throw new IOException("Audio download failed before the track finished.", _pumpError);
                        if (pos < _length - (long)ChunkSize) // not a tail-stall: a real hole
                            throw new IOException("The audio download ended before the track finished.");
                        return 0; // near the tail: serve a clean early EOF
                    }

                    if (!allCached)
                    {
                        if (Environment.TickCount64 - _lastProgressTick > StallTimeoutMs)
                            throw new IOException(
                                $"The audio download stalled: no data received for {StallTimeoutMs / 1000} seconds " +
                                $"at position {pos:N0}.");
                        Monitor.Wait(_gate, 1000);
                        continue;
                    }

                    // Everything needed is on disk — serve it.
                    _cache.Seek(pos, SeekOrigin.Begin);
                    int total = 0;
                    long want = need - pos;
                    while (total < want)
                    {
                        int n = _cache.Read(buffer, offset + total, (int)(want - total));
                        if (n <= 0) break;
                        total += n;
                    }
                    Interlocked.Exchange(ref _playhead, pos + total);

                    long waited = Environment.TickCount64 - started;
                    if (waited > 500)
                        PlaybackLog.Write($"range cache: read {total:N0} at {pos:N0} after waiting {waited} ms");
                    return total;
                }
            }
        }

        public override void Flush() { }
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                try { _cts.Cancel(); } catch (ObjectDisposedException) { }
                try { _pump?.Wait(2000); } catch { }
                try { SaveIndex(); } catch { }
                try { _cache?.Dispose(); } catch { }
                try { _network?.Dispose(); } catch { }
                try { _response?.Dispose(); } catch { }
                _cts.Dispose();
            }
            base.Dispose(disposing);
        }

        private static string Sha1Hex(string text)
        {
            using var sha = SHA1.Create();
            var hash = sha.ComputeHash(Encoding.UTF8.GetBytes(text));
            var sb = new StringBuilder(hash.Length * 2);
            foreach (byte b in hash)
                sb.Append(b.ToString("x2"));
            return sb.ToString();
        }
    }
}
