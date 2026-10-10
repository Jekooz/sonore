using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;

namespace YtMusicClient.Services
{
    public class SidecarLauncher
    {
        private Process _backendProcess;
        private JobObjectHandle _job;
        private int _port;
        private bool _reusedExisting;
        private readonly StringBuilder _backendOutput = new StringBuilder();
        private StreamWriter _logWriter;

        // Backend stdout/stderr land here so a sign-in failure can be diagnosed
        // after the fact instead of vanishing with the process.
        private static readonly string LogFile =
            Path.Combine(Path.GetTempPath(), "ytmusic_backend.log");

        // The backend writes %TEMP%\ytmusic_sidecar_port.txt (see backend/main.py);
        // resolve the same location here instead of the unexpanded literal "%TEMP%\..." string.
        private static readonly string PortFile =
            Path.Combine(Path.GetTempPath(), "ytmusic_sidecar_port.txt");

        /// <summary>True when this launch attached to a sidecar that was already running.</summary>
        public bool ReusedExisting => _reusedExisting;

        /// <summary>PID of the backend this launcher spawned, or 0 when it reused one.</summary>
        public int BackendProcessId { get; private set; }

        /// <summary>
        /// The process settings used for the backend spawn, or null when this
        /// launch reused a running sidecar. Exposed so the launch contract that
        /// keeps the console window away (hidden window + redirected pipes) can
        /// be asserted by tests; the UI never reads it.
        /// </summary>
        public ProcessStartInfo BackendStartInfo { get; private set; }

        public async Task<int> StartupAsync()
        {
            // Reuse a sidecar that is already running. The app is closed and
            // reopened constantly, and the slow part is the Python cold start
            // (imports + uvicorn bind). If a previous instance is still
            // listening on the port it published, attach to it and skip the
            // spawn entirely.
            int existingPort = TryReadPublishedPort();
            if (existingPort > 0 && await AnswersHealthAsync(existingPort))
            {
                _port = existingPort;
                _reusedExisting = true;
                Debug.WriteLine($"Reusing running sidecar on port {existingPort}.");
                return _port;
            }

            if (File.Exists(PortFile))
            {
                try
                {
                    File.Delete(PortFile);
                }
                catch (IOException)
                {
                    // A stale port file is harmless: the health check above
                    // already proved nothing is serving on it.
                }
            }

            var backendScript = FindBackendScript();

            _backendProcess = new Process();
            _backendProcess.StartInfo.FileName = "python";
            _backendProcess.StartInfo.Arguments = $"\"{backendScript}\"";
            _backendProcess.StartInfo.WorkingDirectory = Path.GetDirectoryName(backendScript);
            _backendProcess.StartInfo.UseShellExecute = false;

            // This is what removes the stray terminal window. python.exe is a
            // console-subsystem binary and a WinUI process has no console to
            // inherit, so Windows allocated a brand-new console for it on every
            // launch. Redirecting the pipes does NOT suppress that — verified
            // before the fix: two windows titled "...\Python313\python.exe" with
            // class CASCADIA_HOSTING_WINDOW_CLASS. CreateNoWindow sets
            // CREATE_NO_WINDOW, which stops the console being created at all;
            // WindowStyle=Hidden covers any path that still shows one.
            _backendProcess.StartInfo.CreateNoWindow = true;
            _backendProcess.StartInfo.WindowStyle = ProcessWindowStyle.Hidden;

            _backendProcess.StartInfo.RedirectStandardOutput = true;
            _backendProcess.StartInfo.RedirectStandardError = true;
            BackendStartInfo = _backendProcess.StartInfo;
            try
            {
                _logWriter = new StreamWriter(LogFile, append: true) { AutoFlush = true };
                _logWriter.WriteLine($"--- sidecar starting {DateTime.Now:o} ---");
            }
            catch (IOException)
            {
                _logWriter = null; // logging must never prevent startup
            }

            _backendProcess.OutputDataReceived += CaptureOutput;
            _backendProcess.ErrorDataReceived += CaptureOutput;
            _backendProcess.Start();

            // Bind the backend to a kill-on-close job so it cannot outlive this
            // process, even on a crash or force-kill where no cleanup runs.
            // Assignment can legitimately fail; that only means we fall back to
            // killing it ourselves on a clean exit.
            _job = JobObjectHandle.Create();
            if (_job != null && !_job.Assign(_backendProcess.Handle))
            {
                _job.Dispose();
                _job = null;
            }

            BackendProcessId = _backendProcess.Id;

            // Drain the pipes so a full stdout/stderr buffer cannot stall the backend,
            // and keep the text so a startup failure can be shown to the user instead
            // of being silently swallowed.
            _backendProcess.BeginOutputReadLine();
            _backendProcess.BeginErrorReadLine();

            var deadline = DateTime.UtcNow.AddSeconds(10);
            while (!File.Exists(PortFile))
            {
                if (_backendProcess.HasExited)
                    throw new InvalidOperationException(
                        $"Backend exited early with code {_backendProcess.ExitCode} before writing {PortFile}.");
                if (DateTime.UtcNow > deadline)
                    throw new TimeoutException(
                        $"Backend did not write {PortFile} within 10 seconds.");
                await Task.Delay(200);
            }

            var portText = await File.ReadAllTextAsync(PortFile);
            _port = int.Parse(portText.Trim());
            await EnsureServingAsync(_port);
            return _port;
        }

        /// <summary>Reads the port a previous run advertised, or 0 when there is none.</summary>
        private static int TryReadPublishedPort()
        {
            try
            {
                if (!File.Exists(PortFile))
                    return 0;
                var text = File.ReadAllText(PortFile).Trim();
                return int.TryParse(text, out var port) && port > 0 && port < 65536 ? port : 0;
            }
            catch (IOException)
            {
                return 0;
            }
        }

        /// <summary>
        /// True only if OUR backend answers /health on that port. A squatter on
        /// the same port would accept the connection but not speak this app's
        /// HTTP, so a bare connect would be a false positive.
        /// </summary>
        private static async Task<bool> AnswersHealthAsync(int port)
        {
            try
            {
                using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(2) };
                using var resp = await http.GetAsync($"http://127.0.0.1:{port}/health");
                if (!resp.IsSuccessStatusCode)
                    return false;
                var body = await resp.Content.ReadAsStringAsync();
                return body.Contains("\"ok\"", StringComparison.Ordinal);
            }
            catch (Exception ex) when (ex is HttpRequestException || ex is TaskCanceledException)
            {
                return false;
            }
        }

        private void CaptureOutput(object sender, DataReceivedEventArgs e)
        {
            if (e.Data == null)
                return;

            lock (_backendOutput)
            {
                if (_backendOutput.Length < 16000)
                    _backendOutput.AppendLine(e.Data);

                try
                {
                    _logWriter?.WriteLine(e.Data);
                }
                catch (ObjectDisposedException)
                {
                    // Shutting down; nothing left to log.
                }
            }
        }

        private string ReadBackendOutput()
        {
            lock (_backendOutput)
                return _backendOutput.ToString().Trim();
        }

        /// <summary>
        /// Confirm the backend really answers before handing the port to the UI.
        /// The port file used to be written before uvicorn finished binding, so a
        /// backend that died on "address already in use" still advertised a healthy
        /// port — which surfaced much later as "connection refused" during sign-in.
        /// </summary>
        private async Task EnsureServingAsync(int port)
        {
            using var http = new HttpClient
            {
                BaseAddress = new Uri($"http://127.0.0.1:{port}"),
                Timeout = TimeSpan.FromSeconds(2),
            };

            var deadline = DateTime.UtcNow.AddSeconds(10);
            while (DateTime.UtcNow < deadline)
            {
                if (_backendProcess.HasExited)
                    throw new InvalidOperationException(
                        $"Backend exited with code {_backendProcess.ExitCode} before it started serving. " +
                        ReadBackendOutput());

                try
                {
                    using var resp = await http.GetAsync("/health");
                    if (resp.IsSuccessStatusCode)
                        return;
                }
                catch (Exception ex) when (ex is HttpRequestException || ex is TaskCanceledException)
                {
                    // Not accepting connections yet; keep waiting.
                }

                await Task.Delay(200);
            }

            throw new InvalidOperationException(
                $"Backend did not answer on port {port} within 10 seconds. " + ReadBackendOutput());
        }

        private static string FindBackendScript()
        {
            // Walk up from the executable to the repo root containing backend\main.py.
            // Works from bin\...\net8.0-windows10.0.19041.0 and from `dotnet run`.
            var dir = new DirectoryInfo(AppContext.BaseDirectory);
            while (dir != null)
            {
                var candidate = Path.Combine(dir.FullName, "backend", "main.py");
                if (File.Exists(candidate))
                    return candidate;
                dir = dir.Parent;
            }
            throw new FileNotFoundException(
                "backend\\main.py was not found above " + AppContext.BaseDirectory);
        }

        /// <summary>
        /// Release the launcher's own resources and stop the backend this app
        /// spawned.
        ///
        /// NOTE: this replaces the previous "leave the sidecar running so the next
        /// launch reuses it" behaviour. That deliberate reuse is what produced
        /// orphaned python.exe processes — an earlier build's backend was still
        /// holding a port after its app was killed (observed live: a stray
        /// backend on 8001 while the app's own sidecar sat on 8000). The app now
        /// owns the backend's lifetime; the cost is a Python cold start per launch.
        /// Reuse still happens when a healthy sidecar is already published, so a
        /// leftover from an older build is still adopted rather than duplicated.
        /// </summary>
        public void Shutdown()
        {
            lock (_backendOutput)
            {
                _logWriter?.Dispose();
                _logWriter = null;
            }

            StopBackend();
        }

        /// <summary>
        /// End the backend this app spawned, if any. A reused sidecar belongs to
        /// another process that is still using it, so it is left alone. The whole
        /// process tree is killed because the backend shells out (yt-dlp), and
        /// those children must not be stranded either.
        /// </summary>
        public void StopBackend()
        {
            if (!_reusedExisting && _backendProcess != null)
            {
                try
                {
                    if (!_backendProcess.HasExited)
                        _backendProcess.Kill(entireProcessTree: true);
                }
                catch (InvalidOperationException) { /* never started */ }
                catch (NotSupportedException) { /* no process attached */ }
                catch (Win32Exception) { /* already gone, or access denied */ }
            }

            // Closing the job makes the OS terminate anything still in it, which
            // is the part that also covers a crash where this code never runs.
            _job?.Dispose();
            _job = null;
            _backendProcess = null;
            BackendProcessId = 0;
        }

        public int GetPort()
        {
            return _port;
        }
    }
}
