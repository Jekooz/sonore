using System.Collections.Generic;
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
