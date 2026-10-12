using System;
using System.IO;

namespace YtMusicClient.Services
{
    /// <summary>
    /// Shared log for the playback pipeline (%TEMP%\ytmusic_playback.log),
    /// mirroring the sidecar's backend log. Media Foundation tends to collapse
    /// whatever our stream throws into a generic 0x8000FFFF "Catastrophic
    /// failure", so the real reason a track failed to open only exists here.
    /// Logging must never break playback — failures are swallowed.
    /// </summary>
    public static class PlaybackLog
    {
        private static readonly string LogFile =
            Path.Combine(Path.GetTempPath(), "ytmusic_playback.log");

        private static readonly System.Diagnostics.Stopwatch _clock =
            System.Diagnostics.Stopwatch.StartNew();

        public static void Write(string message)
        {
            try
            {
                // Wall clock + a monotonic relative timestamp: the wall clock
                // anchors logs to real time, the monotonic makes gaps between
                // consecutive lines directly readable for stage timing (e.g.
                // "play requested → stream resolved" is the resolve stage).
                File.AppendAllText(LogFile, $"{DateTime.Now:o} [+{_clock.Elapsed.TotalSeconds:F3}s] {message}{Environment.NewLine}");
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }

        /// <summary>Reset the stage clock so a new track's stages read from 0.</summary>
        public static void ResetClock() => _clock.Restart();
    }
}
