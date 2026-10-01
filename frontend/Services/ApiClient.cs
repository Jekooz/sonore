using System;
using System.Net.Http;
using System.Net.Http.Json;
using System.Text.Json.Serialization;
using System.Threading.Tasks;

namespace YtMusicClient.Services
{
    public class ApiClient
    {
        private readonly HttpClient _client;
        public ApiClient(string baseUrl)
        {
            _client = new HttpClient();
            _client.BaseAddress = new Uri(baseUrl);
        }

        public async Task<bool> CheckHealthAsync()
        {
            var resp = await _client.GetAsync("health");
            return resp.IsSuccessStatusCode;
        }

        public async Task<bool> GetAuthStatusAsync()
        {
            var resp = await _client.GetFromJsonAsync<StatusResponse>("auth/status");
            return resp?.LoggedIn ?? false;
        }

        public async Task<(string verification_url, string user_code)> LoginAsync()
        {
            var resp = await _client.PostAsync("auth/login", null);
            var data = await resp.Content.ReadFromJsonAsync<LoginResponse>();
            return (data.VerificationUrl, data.UserCode);
        }
    }

    // Backend keys are snake_case (FastAPI), so map them explicitly:
    // default JSON options would look for "loggedIn"/"verificationUrl" and never match.
    public class StatusResponse
    {
        [JsonPropertyName("logged_in")]
        public bool LoggedIn { get; set; }
    }

    public class LoginResponse
    {
        [JsonPropertyName("verification_url")]
        public string VerificationUrl { get; set; }
        [JsonPropertyName("user_code")]
        public string UserCode { get; set; }
    }
}
