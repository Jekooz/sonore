using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading.Tasks;

namespace YtMusicClient.Services
{
    /// <summary>
    /// Typed client for the Python sidecar (backend/main.py). Backend JSON is snake_case,
    /// so every response DTO maps field names explicitly.
    /// </summary>
    public class ApiClient
    {
        private readonly HttpClient _client;
        private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

        public ApiClient(string baseUrl)
        {
            _client = new HttpClient { BaseAddress = new Uri(baseUrl), Timeout = TimeSpan.FromSeconds(60) };
        }

        // ---------------- auth ----------------

        public async Task<StatusResponse> GetAuthStatusAsync()
        {
            return await _client.GetFromJsonAsync<StatusResponse>("auth/status", JsonOptions)
                   ?? new StatusResponse { LoggedIn = false };
        }

        /// <summary>
        /// Completes sign-in with cookies captured by the embedded browser.
        /// Returns the verified account info on success.
        /// </summary>
        public async Task<AccountResponse> SendCookiesAsync(Dictionary<string, string> cookies)
        {
            var resp = await _client.PostAsJsonAsync("auth/cookies", new { cookies });
            if (!resp.IsSuccessStatusCode)
            {
                var detail = await ReadErrorDetailAsync(resp);
                throw new ApiRequestException((int)resp.StatusCode, detail);
            }
            var result = await resp.Content.ReadFromJsonAsync<CookieLoginResponse>(JsonOptions);
            return result?.Account ?? new AccountResponse();
        }

        public async Task SignOutAsync()
        {
            await _client.PostAsync("auth/signout", null);
        }

        // ---------------- account + data ----------------

        public async Task<AccountResponse> GetAccountAsync()
        {
            return await GetOrThrowAsync<AccountResponse>("account");
        }

        public async Task<List<HomeRow>> GetHomeAsync()
        {
            return await GetOrThrowAsync<List<HomeRow>>("home");
        }

        public async Task<List<PlaylistSummary>> GetLibraryPlaylistsAsync()
        {
            return await GetOrThrowAsync<List<PlaylistSummary>>("library/playlists");
        }

        public async Task<List<ArtistSummary>> GetLibraryArtistsAsync()
        {
            return await GetOrThrowAsync<List<ArtistSummary>>("library/artists");
        }

        public async Task<List<AlbumSummary>> GetLibraryAlbumsAsync()
        {
            return await GetOrThrowAsync<List<AlbumSummary>>("library/albums");
        }

        public async Task<List<Track>> GetLikedSongsAsync()
        {
            return await GetOrThrowAsync<List<Track>>("library/liked");
        }

        public async Task<List<Track>> GetLibrarySongsAsync()
        {
            return await GetOrThrowAsync<List<Track>>("library/songs");
        }

        public async Task<List<SearchResultGroup>> SearchAsync(string query)
        {
            return await GetOrThrowAsync<List<SearchResultGroup>>($"search?q={Uri.EscapeDataString(query)}");
        }

        // ---------------- helpers ----------------

        private async Task<T> GetOrThrowAsync<T>(string path)
        {
            using var resp = await _client.GetAsync(path);
            if (!resp.IsSuccessStatusCode)
            {
                var detail = await ReadErrorDetailAsync(resp);
                throw new ApiRequestException((int)resp.StatusCode, detail);
            }
            return await resp.Content.ReadFromJsonAsync<T>(JsonOptions);
        }

        private static async Task<string> ReadErrorDetailAsync(HttpResponseMessage resp)
        {
            try
            {
                var err = await resp.Content.ReadFromJsonAsync<ErrorDetail>(JsonOptions);
                return err?.Detail ?? $"Request failed ({(int)resp.StatusCode}).";
            }
            catch (Exception)
            {
                return $"Request failed ({(int)resp.StatusCode}).";
            }
        }
    }

    public class ApiRequestException : Exception
    {
        public int StatusCode { get; }

        public ApiRequestException(int statusCode, string message) : base(message)
        {
            StatusCode = statusCode;
        }
    }

    // ---------------- DTOs (snake_case backend fields) ----------------

    public class StatusResponse
    {
        [JsonPropertyName("logged_in")]
        public bool LoggedIn { get; set; }

        [JsonPropertyName("error")]
        public string Error { get; set; }
    }

    public class ErrorDetail
    {
        [JsonPropertyName("detail")]
        public string Detail { get; set; }
    }

    public class CookieLoginResponse
    {
        [JsonPropertyName("signed_in")]
        public bool SignedIn { get; set; }

        [JsonPropertyName("account")]
        public AccountResponse Account { get; set; }
    }

    /// <summary>accountName / channelHandle / accountPhotoUrl from ytmusicapi get_account_info().</summary>
    public class AccountResponse
    {
        [JsonPropertyName("accountName")]
        public string AccountName { get; set; }

        [JsonPropertyName("channelHandle")]
        public string ChannelHandle { get; set; }

        [JsonPropertyName("accountPhotoUrl")]
        public string AccountPhotoUrl { get; set; }
    }

    /// <summary>One titled row of suggestions from get_home().</summary>
    public class HomeRow
    {
        [JsonPropertyName("title")]
        public string Title { get; set; }

        [JsonPropertyName("contents")]
        public List<HomeItem> Contents { get; set; }
    }

    /// <summary>
    /// A home row card. ytmusicapi items carry whichever id applies (browseId /
    /// playlistId / videoId); we surface them all and let the UI pick.
    /// </summary>
    public class HomeItem
    {
        [JsonPropertyName("title")]
        public string Title { get; set; }

        [JsonPropertyName("browseId")]
        public string BrowseId { get; set; }

        [JsonPropertyName("playlistId")]
        public string PlaylistId { get; set; }

        [JsonPropertyName("videoId")]
        public string VideoId { get; set; }

        [JsonPropertyName("subtitle")]
        public string Subtitle { get; set; }

        [JsonPropertyName("thumbnails")]
        public List<Thumbnail> Thumbnails { get; set; }
    }

    /// <summary>get_library_playlists() item: playlistId / title / thumbnails / count / owned.</summary>
    public class PlaylistSummary
    {
        [JsonPropertyName("playlistId")]
        public string PlaylistId { get; set; }

        [JsonPropertyName("title")]
        public string Title { get; set; }

        [JsonPropertyName("thumbnails")]
        public List<Thumbnail> Thumbnails { get; set; }

        [JsonPropertyName("count")]
        public string Count { get; set; }

        [JsonPropertyName("owned")]
        public bool? Owned { get; set; }
    }

    /// <summary>get_library_artists() item: browseId / artist / subscribers / thumbnails.</summary>
    public class ArtistSummary
    {
        [JsonPropertyName("browseId")]
        public string BrowseId { get; set; }

        [JsonPropertyName("artist")]
        public string Artist { get; set; }

        [JsonPropertyName("subscribers")]
        public string Subscribers { get; set; }

        [JsonPropertyName("thumbnails")]
        public List<Thumbnail> Thumbnails { get; set; }
    }

    /// <summary>get_library_albums() item: browseId / title / type / year / thumbnails.</summary>
    public class AlbumSummary
    {
        [JsonPropertyName("browseId")]
        public string BrowseId { get; set; }

        [JsonPropertyName("title")]
        public string Title { get; set; }

        [JsonPropertyName("type")]
        public string Type { get; set; }

        [JsonPropertyName("year")]
        public string Year { get; set; }

        [JsonPropertyName("thumbnails")]
        public List<Thumbnail> Thumbnails { get; set; }
    }

    /// <summary>
    /// Track from liked songs / library songs (parse_playlist_item):
    /// videoId / title / artists[] / album / duration / thumbnails.
    /// </summary>
    public class Track
    {
        [JsonPropertyName("videoId")]
        public string VideoId { get; set; }

        [JsonPropertyName("title")]
        public string Title { get; set; }

        [JsonPropertyName("artists")]
        public List<ArtistRef> Artists { get; set; }

        [JsonPropertyName("album")]
        public AlbumRef Album { get; set; }

        [JsonPropertyName("duration")]
        public string Duration { get; set; }

        [JsonPropertyName("duration_seconds")]
        public int? DurationSeconds { get; set; }

        [JsonPropertyName("thumbnails")]
        public List<Thumbnail> Thumbnails { get; set; }

        [JsonPropertyName("isExplicit")]
        public bool? IsExplicit { get; set; }

        public string ArtistText => Artists != null && Artists.Count > 0
            ? string.Join(", ", Artists)
            : Album?.Name ?? "";
    }

    public class ArtistRef
    {
        [JsonPropertyName("name")]
        public string Name { get; set; }

        [JsonPropertyName("id")]
        public string Id { get; set; }

        public override string ToString() => Name;
    }

    public class AlbumRef
    {
        [JsonPropertyName("name")]
        public string Name { get; set; }

        [JsonPropertyName("id")]
        public string Id { get; set; }
    }

    /// <summary>
    /// search() returns a mixed list of songs / albums / artists / playlists etc.,
    /// each identifiable by which id field is present + its "category" text.
    /// </summary>
    public class SearchResultGroup
    {
        [JsonPropertyName("category")]
        public string Category { get; set; }

        [JsonPropertyName("resultType")]
        public string ResultType { get; set; }

        [JsonPropertyName("title")]
        public string Title { get; set; }

        [JsonPropertyName("artist")]
        public string Artist { get; set; }

        [JsonPropertyName("videoId")]
        public string VideoId { get; set; }

        [JsonPropertyName("browseId")]
        public string BrowseId { get; set; }

        [JsonPropertyName("playlistId")]
        public string PlaylistId { get; set; }

        [JsonPropertyName("thumbnails")]
        public List<Thumbnail> Thumbnails { get; set; }
    }

    public class Thumbnail
    {
        [JsonPropertyName("url")]
        public string Url { get; set; }

        [JsonPropertyName("width")]
        public int Width { get; set; }

        [JsonPropertyName("height")]
        public int Height { get; set; }

        /// <summary>Pick the largest thumbnail at or under maxWidth, else the largest.</summary>
        public static string PickUrl(List<Thumbnail> thumbs, int maxWidth = 544)
        {
            if (thumbs == null || thumbs.Count == 0)
                return null;
            Thumbnail best = null;
            foreach (var t in thumbs)
            {
                if (t?.Url == null) continue;
                if (best == null || (t.Width <= maxWidth && t.Width > best.Width) || (best.Width > maxWidth && t.Width < best.Width))
                    best = t;
            }
            return best?.Url ?? thumbs[0].Url;
        }
    }
}
