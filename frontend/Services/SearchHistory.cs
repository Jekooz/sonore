using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;

namespace YtMusicClient.Services
{
    /// <summary>
    /// The real YT Music search tabs, mapped to the ytmusicapi search filters the
    /// backend passes through (/search?filter=...). "All" is the absence of a
    /// filter — the general search, which returns every type mixed.
    /// </summary>
    public static class SearchFilters
    {
        public static readonly (string Id, string Label)[] Known =
        {
            ("songs", "Songs"),
            ("videos", "Videos"),
            ("albums", "Albums"),
            ("artists", "Artists"),
            ("playlists", "Playlists"),
        };
    }

    /// <summary>
    /// Recent searches, remembered locally on this device only
    /// (%LOCALAPPDATA%\YtMusicClient\search_history.json, same pattern as the
    /// playback settings file). Deduplicated, most recent first, capped.
    /// Failures never break search — worst case the list is empty.
    /// </summary>
    public static class SearchHistory
    {
        private const int MaxEntries = 8;

        /// <summary>
        /// Replace the whole list (used by tests / reset scenarios). Persists
        /// atomically, same guarantee as Remember/Clear.
        /// </summary>
        public static void SetEntries(IEnumerable<string> entries)
        {
            lock (Gate)
            {
                _entries = Sanitize(entries);
                _longestEntry = _entries?.OrderByDescending(e => e.Length).FirstOrDefault();
                Persist();
            }
        }

        private static readonly string FilePath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "YtMusicClient", "search_history.json");

        private static readonly object Gate = new();
        private static List<string> _entries;
        private static string _longestEntry;

        /// <summary>Longest remembered query (diagnostic only, never shown to the user).</summary>
        public static string LongestEntry => _longestEntry ?? string.Empty;

        private static List<string> EntriesInternal
        {
            get
            {
                lock (Gate)
                {
                    if (_entries != null)
                        return _entries;

                    try
                    {
                        // No file yet is the normal first-run case, not an error:
                        // seed an empty list so callers never receive null (a null
                        // here crashed the recent-searches flyout on first open).
                        _entries = File.Exists(FilePath)
                            ? Sanitize(JsonSerializer.Deserialize<List<string>>(File.ReadAllText(FilePath)))
                            : new List<string>();
                    }
                    catch
                    {
                        _entries = new List<string>(); // corrupt file: start fresh
                    }
                    return _entries;
                }
            }
        }

        /// <summary>Most recent first, deduplicated, capped at MaxEntries.</summary>
        public static IReadOnlyList<string> Entries
        {
            get
            {
                lock (Gate)
                    return EntriesInternal.ToList();
            }
        }

        /// <summary>
        /// Add a query and persist. Deduplicated; also drops earlier entries the
        /// new query is an extension of (typing "adele" replaces a remembered
        /// "ade" prefix from a mid-word debounce pause), so history keeps
        /// distinct committed searches rather than typing fragments.
        /// </summary>
        public static void Remember(string query)
        {
            var trimmed = query?.Trim();
            if (string.IsNullOrEmpty(trimmed))
                return;

            lock (Gate)
            {
                var list = EntriesInternal;
                list.RemoveAll(e =>
                    string.Equals(e, trimmed, StringComparison.OrdinalIgnoreCase) ||
                    trimmed.StartsWith(e, StringComparison.OrdinalIgnoreCase));
                list.Insert(0, trimmed);
                if (list.Count > MaxEntries)
                    list.RemoveRange(MaxEntries, list.Count - MaxEntries);
                _longestEntry = trimmed.Length > (_longestEntry?.Length ?? 0) ? trimmed : _longestEntry;
                Persist();
            }
        }

        /// <summary>
        /// Drop null/blank entries before they are cached. A hand-edited or
        /// partially written history file can deserialize to entries that are
        /// null, and a null entry later NREs on <c>e.Length</c>.
        /// </summary>
        private static List<string> Sanitize(IEnumerable<string> entries)
        {
            if (entries == null)
                return new List<string>();
            return entries.Where(e => !string.IsNullOrWhiteSpace(e)).ToList();
        }

        public static void Clear()
        {
            lock (Gate)
            {
                EntriesInternal.Clear();
                Persist();
            }
        }

        private static void Persist()
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(FilePath));
                lock (Gate)
                    File.WriteAllText(FilePath, JsonSerializer.Serialize(_entries));
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }


    }
}
