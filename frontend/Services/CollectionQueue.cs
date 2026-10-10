using System;
using System.Text.Json;
using System.Threading.Tasks;

namespace YtMusicClient.Services
{
    /// <summary>
    /// What a collection card hands to the shell: the already-resolved
    /// collection (header + tracks) plus the card's own art, which is the
    /// fallback when the backend response carries no thumbnails.
    /// </summary>
    public sealed class CollectionRequest
    {
        public CollectionRequest(CollectionDetail detail, string fallbackArtUrl)
        {
            Detail = detail;
            FallbackArtUrl = fallbackArtUrl;
        }

        public CollectionDetail Detail { get; }

        public string FallbackArtUrl { get; }
    }

    /// <summary>
    /// Turns an album/playlist/artist card into a browsable collection.
    ///
    /// Home, Library and Search cards carry only an id for collections: a
    /// browseId for albums (MPREb…) and artists (UC…), or a playlistId. Without
    /// this resolver those cards could not open anything, which is why only
    /// single songs used to play. The header and the track list always come from
    /// the backend's real ytmusicapi calls (/album, /playlist, /artist) — never
    /// synthesized — so one fetch feeds both the tracklist and the queue.
    /// </summary>
    internal static class CollectionQueue
    {
        /// <summary>
        /// Resolve a card's id to a real collection. The id decides the endpoint:
        /// a playlistId is a playlist, a browseId starting with MPREb is an album
        /// and one starting with UC is an artist — the same distinctions
        /// ytmusicapi itself uses. Returns null when the card is not a resolvable
        /// collection, or the backend refuses, so callers can leave the click
        /// alone rather than open an empty page.
        /// </summary>
        public static async Task<CollectionDetail> ResolveAsync(string browseId, string playlistId)
        {
            if (App.ApiClient == null)
                return null;

            try
            {
                // browseId is checked first on purpose: an album search result
                // carries BOTH its album browseId (MPREb…) and the album's backing
                // audio playlist (OLAK5uy…). Preferring the playlistId made an
                // album open as a "Playlist" with playlist metadata. A playlist
                // result's browseId is "VL"+id, which matches neither prefix, so
                // it still falls through to the playlistId branch below.
                // Verified id shapes from the real backend: albums are MPREb…,
                // library artists are MPL… while channel subscriptions are UC…,
                // and a playlist result's browseId is VL+id. Both artist prefixes
                // are accepted because get_artist() takes either one — matching
                // only "UC" silently skipped every artist in Your Library.
                if (!string.IsNullOrEmpty(browseId))
                {
                    if (browseId.StartsWith("MPREb", StringComparison.Ordinal))
                        return await App.ApiClient.GetAlbumDetailAsync(browseId);

                    if (browseId.StartsWith("UC", StringComparison.Ordinal)
                        || browseId.StartsWith("MPL", StringComparison.Ordinal))
                        return await App.ApiClient.GetArtistDetailAsync(browseId);
                }

                if (!string.IsNullOrEmpty(playlistId))
                    return await App.ApiClient.GetPlaylistDetailAsync(playlistId);

                return null;
            }
            catch (Exception ex) when (ex is ApiRequestException || ex is JsonException)
            {
                // These clicks run from `async void` handlers, so an escaping
                // exception here takes down the process with no user-visible
                // cause. Record it and leave the click as a no-op instead.
                App.LogCrash($"CollectionQueue.ResolveAsync({browseId}, {playlistId})", ex);
                return null;
            }
        }
    }
}
