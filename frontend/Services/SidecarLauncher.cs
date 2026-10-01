using System;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;

namespace YtMusicClient.Services
{
    public class SidecarLauncher
    {
        private Process _backendProcess;
        private int _port;

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
            _backendProcess.Start();

            // Drain the pipes so a full stdout/stderr buffer cannot stall the backend.
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
            return _port;
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
        }

        public int GetPort()
        {
            return _port;
        }
    }
}
