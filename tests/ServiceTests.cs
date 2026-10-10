using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using Xunit;
using YtMusicClient.Services;

namespace YtMusicClient.Tests;

public class QueueManagerTests
{
    [Fact]
    public void Sync_Populates_Current_And_HasUpcoming()
    {
        var qm = new QueueManager();
        var queue = new List<QueueTrack>
        {
            new("v1", "Track One", "Artist", "art1.png"),
            new("v2", "Track Two", "Artist", "art2.png"),
            new("v3", "Track Three", "Artist", "art3.png")
        };

        qm.Sync(queue, 1);

        Assert.NotNull(qm.Current);
        Assert.Equal("Track Two", qm.Current.Title);
        Assert.NotNull(qm.Previous);
        Assert.Equal("Track One", qm.Previous.Title);
        Assert.True(qm.HasUpcoming);
        Assert.Equal(1, qm.Upcoming.Count);
        Assert.Equal("Track Three", qm.Upcoming[0].Title);
    }

    [Fact]
    public void Sync_EmptyQueue_LeafTrack_HasNoUpcoming()
    {
        var qm = new QueueManager();
        var queue = new List<QueueTrack> { new("v1", "Only", "A", "a.png") };

        qm.Sync(queue, 0);

        Assert.NotNull(qm.Current);
        Assert.Null(qm.Previous);
        Assert.False(qm.HasUpcoming);
        Assert.Empty(qm.Upcoming);
    }

    [Fact]
    public void Sync_NullIndex_Resets_State()
    {
        var qm = new QueueManager();
        qm.Sync(new List<QueueTrack>(), -1);

        Assert.Null(qm.Current);
        Assert.Null(qm.Previous);
        Assert.False(qm.HasUpcoming);
        Assert.Empty(qm.Upcoming);
    }
}

public class SearchHistoryTests
{
    private static readonly string FilePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "YtMusicClient", "search_history.json");

    /// <summary>Drop the lazy cache back to its unloaded state so the next read
    /// behaves like the first access in a fresh process.</summary>
    private static void ResetStaticState()
    {
        const BindingFlags Flags = BindingFlags.NonPublic | BindingFlags.Static;
        var type = typeof(SearchHistory);
        type.GetField("_entries", Flags)?.SetValue(null, null);
        type.GetField("_longestEntry", Flags)?.SetValue(null, null);
    }

    /// <summary>
    /// Regression: on a first run there is no history file yet, and the lazy
    /// loader used to leave its cache null in that case. The first open of the
    /// recent-searches flyout then did <c>EntriesInternal.ToList()</c> and threw
    /// ArgumentNullException ("Value cannot be null. (Parameter 'source')") out
    /// of the flyout's Opened handler, which WinUI turns into a stowed 0xC000027B
    /// process kill — the reported crash.
    /// </summary>
    [Fact]
    public void Entries_NoFileYet_ReturnsEmptyInsteadOfThrowing()
    {
        string backup = File.Exists(FilePath) ? File.ReadAllText(FilePath) : null;
        try
        {
            if (File.Exists(FilePath))
                File.Delete(FilePath);
            ResetStaticState();

            var entries = SearchHistory.Entries; // the exact call that crashed

            Assert.NotNull(entries);
            Assert.Empty(entries);
        }
        finally
        {
            ResetStaticState();
            if (backup != null)
                File.WriteAllText(FilePath, backup);
        }
    }
}

public class SidecarLauncherTests
{
    /// <summary>
    /// Two launchers alive at once must share one sidecar rather than starting a
    /// second copy. The app no longer depends on this for a warm start (it now
    /// stops the backend it spawned on close), but the reuse path is still what
    /// adopts a sidecar left behind by an older build instead of duplicating it.
    /// </summary>
    [Fact]
    public async Task Startup_Twice_ReusesTheRunningSidecar()
    {
        var first = new SidecarLauncher();
        var second = new SidecarLauncher();
        try
        {
            int firstPort = await first.StartupAsync();
            int secondPort = await second.StartupAsync();

            Assert.True(second.ReusedExisting,
                "The second StartupAsync should have reused the running sidecar.");
            Assert.Equal(firstPort, secondPort);
        }
        finally
        {
            // Only kills a backend this test actually spawned; a reused one is
            // left alone (StopBackend is a no-op when ReusedExisting is true).
            first.StopBackend();
            second.StopBackend();
        }
    }

    /// <summary>
    /// The spawn contract and its teardown, together, because both are about the
    /// same guarantee: a backend this app starts is invisible and does not
    /// outlive it.
    ///
    /// Regression guard for the stray terminal window: python.exe is a
    /// console-subsystem binary and a WinUI app has no console to inherit, so
    /// without CreateNoWindow Windows gave the sidecar its own visible console
    /// (confirmed before the fix: windows titled "...\Python313\python.exe"
    /// hosted by WindowsTerminal).
    /// </summary>
    [Fact]
    public async Task SpawnedBackend_IsHidden_AndIsTerminatedOnStop()
    {
        // Force the spawn path: with no published port file the launcher cannot
        // adopt an existing sidecar, so it must start its own.
        string portFile = Path.Combine(Path.GetTempPath(), "ytmusic_sidecar_port.txt");
        string? backup = File.Exists(portFile) ? File.ReadAllText(portFile) : null;
        if (File.Exists(portFile))
            File.Delete(portFile);

        var launcher = new SidecarLauncher();
        try
        {
            await launcher.StartupAsync();

            Assert.False(launcher.ReusedExisting, "the port file was removed, so this must be a fresh spawn");

            var info = launcher.BackendStartInfo;
            Assert.NotNull(info);
            Assert.True(info!.CreateNoWindow, "CreateNoWindow is what stops the console window appearing");
            Assert.Equal(ProcessWindowStyle.Hidden, info.WindowStyle);
            Assert.False(info.UseShellExecute, "CreateNoWindow only takes effect with UseShellExecute = false");
            Assert.True(info.RedirectStandardOutput);
            Assert.True(info.RedirectStandardError);

            Assert.True(launcher.BackendProcessId > 0, "a spawned backend must report its pid");
            int pid = launcher.BackendProcessId;

            launcher.StopBackend();

            Assert.True(WaitForProcessExit(pid, 10000),
                $"pid {pid} must be gone after StopBackend — a surviving backend is the orphan bug");
        }
        finally
        {
            launcher.Shutdown();

            // Leave the machine as the test found it.
            if (backup != null)
                File.WriteAllText(portFile, backup);
            else if (File.Exists(portFile))
                File.Delete(portFile);
        }
    }

    /// <summary>True once the pid no longer exists (or very shortly after a kill).</summary>
    private static bool WaitForProcessExit(int pid, int timeoutMs)
    {
        var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (DateTime.UtcNow < deadline)
        {
            try
            {
                using var process = Process.GetProcessById(pid);
                if (process.HasExited)
                    return true;
            }
            catch (ArgumentException)
            {
                return true; // no such process
            }

            Thread.Sleep(100);
        }

        return false;
    }
}
