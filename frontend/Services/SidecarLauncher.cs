using System;
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
        private int _port;
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

        public async Task<int> StartupAsync()
        {
            if (File.Exists(PortFile))
                File.Delete(PortFile);

            var backendScript = FindBackendScript();

            _backendProcess = new Process();
            _backendProcess.StartInfo.FileName = "python";
            _backendProcess.StartInfo.Arguments = $"\"{backendScript}\"";
            _backendProcess.StartInfo.WorkingDirectory = Path.GetDirectoryName(backendScript);
            _backendProcess.StartInfo.UseShellExecute = false;
            _backendProcess.StartInfo.RedirectStandardOutput = true;
            _backendProcess.StartInfo.RedirectStandardError = true;
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

        public void Shutdown()
        {
            if (_backendProcess != null && !_backendProcess.HasExited)
                _backendProcess.Kill();

            lock (_backendOutput)
            {
                _logWriter?.Dispose();
                _logWriter = null;
            }
        }

        public int GetPort()
        {
            return _port;
        }
    }
}
