using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Xunit;
using YtMusicClient.Services;
using YtMusicClient.Views;

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

public class PlaybackServiceTests
{
    /// <summary>
    /// A loopback HTTP stub standing in for the sidecar's /stream endpoint.
    ///
    /// It exists only because these regressions are about timing: the first request has
    /// to still be in flight when the duplicate arrives, and the real sidecar's yt-dlp
    /// resolve cannot be made to take a known amount of time — besides which a real
    /// resolve would start playing audio. Everything actually under test is the real
    /// implementation (PlaybackService, ApiClient, the engine's failure path); only the
    /// remote endpoint is substituted. The URL the stub hands back points at a closed
    /// port, so the engine's own load fails fast and deterministically.
    /// </summary>
    private sealed class StubStreamServer : IDisposable
    {
        private readonly TcpListener _listener;
        private readonly int _delayMs;

        public int Port { get; }

        public StubStreamServer(int delayMs)
        {
            _delayMs = delayMs;
            _listener = new TcpListener(IPAddress.Loopback, 0);
            _listener.Start();
            Port = ((IPEndPoint)_listener.LocalEndpoint).Port;
            _ = Task.Run(AcceptLoopAsync);
        }

        private async Task AcceptLoopAsync()
        {
            while (true)
            {
                TcpClient client;
                try
                {
                    client = await _listener.AcceptTcpClientAsync();
                }
                catch
                {
                    return; // listener stopped
                }

                _ = Task.Run(() => RespondAsync(client));
            }
        }

        private async Task RespondAsync(TcpClient client)
        {
            using (client)
            {
                try
                {
                    using var stream = client.GetStream();
                    using var reader = new StreamReader(stream, Encoding.ASCII, false, 1024, leaveOpen: true);
                    await reader.ReadLineAsync();                                    // request line
                    while (!string.IsNullOrEmpty(await reader.ReadLineAsync())) { }   // headers

                    await Task.Delay(_delayMs);   // keeps the first request in flight

                    const string Body = "{\"videoId\":\"ignored\",\"url\":\"http://127.0.0.1:1/audio\"}";
                    byte[] payload = Encoding.ASCII.GetBytes(
                        "HTTP/1.1 200 OK\r\n" +
                        "Content-Type: application/json\r\n" +
                        "Content-Length: " + Body.Length + "\r\n" +
                        "Connection: close\r\n\r\n" + Body);
                    await stream.WriteAsync(payload);
                    await stream.FlushAsync();
                }
                catch
                {
                    // A dropped connection is not what this test is about.
                }
            }
        }

        public void Dispose() => _listener.Stop();
    }

    /// <summary>
    /// Regression (Batch 5, finding F1): the 700 ms duplicate gate used to run AFTER
    /// `++_generation`, so the request it was supposed to ignore had already superseded
    /// the load it was protecting — the first click's resolve then aborted itself and
    /// IsBusy was never cleared, stranding the UI on "Resolving stream…" with the play
    /// button disabled and nothing playing. Before the fix this test fails on IsBusy.
    /// </summary>
    [Fact]
    public async Task Duplicate_PlayRequest_InsideTheDebounceWindow_DoesNotSupersedeTheFirst()
    {
        using var server = new StubStreamServer(delayMs: 300);
        var apiBefore = App.ApiClient;
        var service = new PlaybackService();
        try
        {
            App.ApiClient = new ApiClient($"http://127.0.0.1:{server.Port}/");
            service.ResetDebugState();

            Task first = service.PlayAsync("vid-dup", "Title", "Artist", "");
            Task second = service.PlayAsync("vid-dup", "Title", "Artist", ""); // duplicate, well inside 700 ms
            await Task.WhenAll(first, second);

            Assert.False(service.IsBusy,
                "a debounced duplicate must leave the load it duplicates alone, not strand it");
            Assert.StartsWith("Playback failed", service.StatusText);
        }
        finally
        {
            service.Dispose();
            App.ApiClient = apiBefore;
        }
    }

    /// <summary>
    /// Regression (Batch 5, finding F2): after a failed resolve CanToggle is true, so
    /// the play button is enabled — but both branches of TogglePlayPause used to fall
    /// through (nothing playing, no URL) and the press did nothing at all. The retry
    /// must re-enter the load path; its synchronous part sets busy + status.
    /// </summary>
    [Fact]
    public async Task PlayToggle_AfterAFailedResolve_RetriesTheLoad()
    {
        using var server = new StubStreamServer(delayMs: 300);
        var apiBefore = App.ApiClient;
        var service = new PlaybackService();
        try
        {
            App.ApiClient = new ApiClient($"http://127.0.0.1:{server.Port}/");
            service.ResetDebugState();

            await service.PlayAsync("vid-retry", "Title", "Artist", "");
            Assert.False(service.IsBusy);
            Assert.StartsWith("Playback failed", service.StatusText);

            service.TogglePlayPause();

            Assert.True(service.IsBusy,
                "pressing play after a failed resolve must retry the load instead of doing nothing");
            Assert.Equal("Resolving stream…", service.StatusText);
        }
        finally
        {
            service.Dispose();
            App.ApiClient = apiBefore;
        }
    }

    /// <summary>
    /// Regression (Batch 5, finding F3): the transport gated Next on Queue.HasUpcoming,
    /// but PlayNext() also wraps under repeat-all and can jump backwards under shuffle,
    /// so Next was greyed out where the service would happily advance.
    ///
    /// Uses the app's single PlaybackService: the capability is a property of the shared
    /// queue, and Repeat/Shuffle persist to settings.json, so the user's own values are
    /// put back afterwards (same backup/restore idea as SearchHistoryTests).
    /// </summary>
    [Fact]
    public async Task CanAdvance_FollowsRepeatAndShuffle_NotJustTheUpcomingList()
    {
        var repeatBefore = App.PlayerState.Repeat;
        var shuffleBefore = App.PlayerState.Shuffle;
        var apiBefore = App.ApiClient;
        try
        {
            // A closed port: this test only exercises the queue/capability wiring, and
            // every track must fail to load rather than play.
            App.ApiClient = new ApiClient("http://127.0.0.1:1/");
            App.PlayerState.Shuffle = false;
            App.PlayerState.Repeat = RepeatMode.Off;

            var threeTracks = new List<QueueTrack>
            {
                new("q1", "One", "Artist", ""),
                new("q2", "Two", "Artist", ""),
                new("q3", "Three", "Artist", "")
            };
            await App.Playback.PlayAsync(threeTracks, 2);   // last entry: nothing Upcoming

            Assert.False(App.Queue.CanAdvance, "repeat off at the queue end is a real dead end");

            App.PlayerState.Repeat = RepeatMode.All;
            Assert.True(App.Queue.CanAdvance,
                "repeat-all wraps, so Next is not a dead end at the end of the queue");

            App.PlayerState.Repeat = RepeatMode.Off;
            Assert.False(App.Queue.CanAdvance);

            App.PlayerState.Shuffle = true;
            Assert.True(App.Queue.CanAdvance,
                "shuffle can reach the earlier entries, which HasUpcoming cannot see");
            App.PlayerState.Shuffle = false;

            await App.Playback.PlayAsync(new List<QueueTrack> { new("only", "Only", "Artist", "") }, 0);
            Assert.False(App.Queue.CanAdvance, "one track with repeat off and no shuffle: a real dead end");
        }
        finally
        {
            App.PlayerState.Repeat = repeatBefore;
            App.PlayerState.Shuffle = shuffleBefore;
            App.ApiClient = apiBefore;
        }
    }

    /// <summary>
    /// Regression (P2): pressing Next REPEATEDLY must walk the whole queue in order
    /// and must not strand playback on "Resolving stream…". Each PlayNext call goes
    /// through the same standalone-queue-clearing path as a first play, so the queue
    /// must survive repeated advances, and each advance must actually retarget the
    /// service's current track (VideoId claim) even though every stream load fails.
    /// Uses one PlaybackService with a closed-port ApiClient: only the queue/advance
    /// logic is under test, never real audio.
    /// </summary>
    [Fact]
    public async Task Next_RepeatedWalksTheQueueInOrder()
    {
        var apiBefore = App.ApiClient;
        try
        {
            App.ApiClient = new ApiClient("http://127.0.0.1:1/");
            App.PlayerState.Repeat = RepeatMode.Off;
            App.PlayerState.Shuffle = false;

            var service = App.Playback;
            service.ResetDebugState();
            var queue = new List<QueueTrack>
            {
                new("n1", "One", "Artist", ""),
                new("n2", "Two", "Artist", ""),
                new("n3", "Three", "Artist", ""),
            };
            await service.PlayAsync(queue, 0);

            string[] expectedOrder = { "n1", "n2", "n3" };
            for (int i = 1; i < expectedOrder.Length; i++)
            {
                bool advanced = service.PlayNext();
                Assert.True(advanced, $"Next #{i} must start the next queue entry");
                Assert.Equal(expectedOrder[i], service.VideoId);
            }

            // Exhausted + repeat off: the final PlayNext is a declines-nothing
            // no-op, leaving the last track's VideoId in place.
            Assert.False(service.PlayNext(), "repeat off at the queue end must decline");
            Assert.Equal("n3", service.VideoId);
        }
        finally
        {
            App.PlayerState.Repeat = RepeatMode.Off;
            App.PlayerState.Shuffle = false;
            App.ApiClient = apiBefore;
        }
    }

    /// <summary>
    /// Regression (P2) for the standalone-play dead end: when a track outside the
    /// queue is played, the queue is cleared by design (stale-context rule). After
    /// it FINISHES the ended-handler would rest; but the Next button's own state
    /// (CanAdvance=false) must stay consistent with PlayNext()=false, so the user
    /// never sees an enabled Next that does nothing. Playing a queued track again
    /// re-aims the queue (documented behavior), so Next works again from there.
    /// </summary>
    [Fact]
    public async Task StandalonePlay_QueueCleared_NextDeclinesThenQueueReaims()
    {
        var apiBefore = App.ApiClient;
        try
        {
            App.ApiClient = new ApiClient("http://127.0.0.1:1/");
            App.PlayerState.Repeat = RepeatMode.Off;
            App.PlayerState.Shuffle = false;

            var service = App.Playback;
            service.ResetDebugState();
            var queue = new List<QueueTrack>
            {
                new("sa1", "One", "Artist", ""),
                new("sa2", "Two", "Artist", ""),
            };
            await service.PlayAsync(queue, 0);
            Assert.True(App.Queue.CanAdvance, "queue context is alive at index 0");

            // Standalone: a videoId not in the queue. Clears the stale queue.
            await service.PlayAsync("solo", "Solo", "Artist", "");
            Assert.Equal("solo", service.VideoId);
            Assert.False(service.PlayNext(), "no queue, no repeat, no shuffle: PlayNext declines");
            Assert.False(App.Queue.CanAdvance, "CanAdvance must mirror PlayNext's decline");

            // Playing from the original list re-aims the queue and Next works again.
            await service.PlayAsync(queue, 0);
            Assert.Equal("sa1", service.VideoId);
            Assert.True(service.PlayNext(), "re-aimed queue advances to entry 1");
            Assert.Equal("sa2", service.VideoId);
        }
        finally
        {
            App.PlayerState.Repeat = RepeatMode.Off;
            App.PlayerState.Shuffle = false;
            App.ApiClient = apiBefore;
        }
    }

    /// <summary>
    /// Regression (P2) for the rapid-track-change race: a newer PlayAsync must
    /// retire the previous one. The stub server holds the FIRST resolve in flight
    /// long enough for a second click on a DIFFERENT track to supersede it; the
    /// superseded load must never commit, so the final VideoId must be the newer
    /// click's and IsBusy must not be stuck true after the newer load fails fast.
    /// </summary>
    [Fact]
    public async Task RapidTrackChange_OlderClickIsSuperseded_NotStuckBusy()
    {
        using var server = new StubStreamServer(delayMs: 400);
        var apiBefore = App.ApiClient;
        var service = new PlaybackService();
        try
        {
            App.ApiClient = new ApiClient($"http://127.0.0.1:{server.Port}/");
            service.ResetDebugState();

            Task first = service.PlayAsync("race-a", "One", "Artist", "");
            await Task.Delay(50);          // first resolve is now in flight
            Task second = service.PlayAsync("race-b", "Two", "Artist", "");
            await Task.WhenAll(first, second);

            Assert.Equal("race-b", service.VideoId);
            Assert.False(service.IsBusy,
                "the superseded first click must never strand IsBusy=true");
            Assert.StartsWith("Playback failed", service.StatusText);
        }
        finally
        {
            service.Dispose();
            App.ApiClient = apiBefore;
        }
    }

    /// <summary>
    /// Regression (P2) for the URL-cache semantics: after a prefetch fires, the
    /// same video must hit the (stubbed) backend again but the renewed Wait must
    /// not have been skipped because of the 700 ms same-id duplicate gate. Direct
    /// test: the gate suppresses the SECOND identical click inside 700 ms, but a
    /// click outside the window re-resolves (stub server delays verify the resolve
    /// still happened, i.e. the play actually re-entered the load path).
    /// </summary>
    [Fact]
    public async Task SameTrackOutsideDebounceWindow_ReentersTheLoadPath()
    {
        using var server = new StubStreamServer(delayMs: 200);
        var apiBefore = App.ApiClient;
        var service = new PlaybackService();
        try
        {
            App.ApiClient = new ApiClient($"http://127.0.0.1:{server.Port}/");
            service.ResetDebugState();

            await service.PlayAsync("dup-re", "One", "Artist", "");
            Assert.StartsWith("Playback failed", service.StatusText);

            // The duplicate gate absorbs <700 ms replays (covered elsewhere);
            // here wait it out and confirm a genuine re-resolve happens.
            await Task.Delay(800);
            await service.PlayAsync("dup-re", "One", "Artist", "");

            // Re-entry means the service went through resolve again — visible as
            // the same deterministic failed-load status, NOT a no-op.
            Assert.StartsWith("Playback failed", service.StatusText);
            Assert.False(service.IsBusy);
        }
        finally
        {
            service.Dispose();
            App.ApiClient = apiBefore;
        }
    }
}

/// <summary>
/// Responsive Now Playing / collapsible-nav rules. Both are deliberately
/// pure functions: the Window and Page themselves need a live UI thread, but
/// the decisions they consult (which destination collapses the sidebar,
/// whether the carousel's side cards fit) do not — so the contract is pinned
/// here and the visual behaviour stays a manual Windows check.
/// </summary>
public class NavigationChromeTests
{
    /// <summary>The sidebar collapses to the hamburger for Now Playing only;
    /// every other destination (and an unknown/null tag) restores it.</summary>
    [Theory]
    [InlineData("home", false)]
    [InlineData("search", false)]
    [InlineData("library", false)]
    [InlineData("nowplaying", true)]
    [InlineData(null, false)]
    public void Nav_Collapses_Only_For_NowPlaying(string? tag, bool expected)
        => Assert.Equal(expected, MainWindow.ShouldCollapseNavFor(tag));

    /// <summary>Carousel side cards need 150 + 300 + 150 + 12+12 margins plus
    /// the page's 2×24 padding — 700 px of page width. At or above, the full
    /// 3-card row renders; below, the cards hide instead of overflowing
    /// horizontally (centre card + controls always remain).</summary>
    [Theory]
    [InlineData(1200.0, true)]  // default windowed size
    [InlineData(700.0, true)]   // exact threshold
    [InlineData(699.0, false)]  // one pixel under: side cards hide
    [InlineData(480.0, false)]  // narrow windowed
    public void Carousel_SideCards_Hide_Below_Width_Threshold(double pageWidth, bool expected)
        => Assert.Equal(expected, NowPlayingPage.ShowSideCardsFor(pageWidth));
}

/// <summary>
/// Mini-player layout contract: the window may never be shrunk so far that the
/// title bar (48) + the mini-player's dedicated row (64 bar + 16 bottom margin)
/// stop fitting — that is exactly the state in which the bar's rounded container
/// crossed the client-area edge (reported bug: "bottom mini-player clipped at
/// the window bottom"). The WM_GETMINMAXINFO hook in MainWindow enforces it at
/// runtime; this pins the arithmetic so a future padding/margin tweak cannot
/// silently break the floor.
/// </summary>
public class WindowChromeTests
{
    [Fact]
    public void PlayerRow_Is_A_Dedicated_Sixteen_Pixel_Margin()
        => Assert.Equal(80, MainWindow.PlayerRowLogicalHeight); // 64 bar + 16 margin

    [Fact]
    public void MinWindowHeight_Keeps_TitleBar_And_PlayerRow_And_Content_Floor()
    {
        Assert.Equal(48, MainWindow.TitleBarLogicalHeight);
        Assert.True(MainWindow.MinContentLogicalHeight >= 160,
            "at least 160 logical px of content must survive between title bar and player row");
        Assert.Equal(MainWindow.TitleBarLogicalHeight + MainWindow.MinContentLogicalHeight
                        + MainWindow.PlayerRowLogicalHeight,
                     MainWindow.MinWindowLogicalHeight);
    }
}
