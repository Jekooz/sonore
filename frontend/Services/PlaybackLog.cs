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

        public static void Write(string message)
        {
            try
            {
                File.AppendAllText(LogFile, $"{DateTime.Now:o} {message}{Environment.NewLine}");
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
