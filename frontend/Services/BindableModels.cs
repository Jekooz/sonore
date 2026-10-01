using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;

namespace YtMusicClient.Services
{
    /// <summary>
    /// Thin bindable wrappers around the backend DTOs for XAML data templates.
    /// They precompute the display image URL so templates bind one property
    /// instead of calling helper methods inside {x:Bind}.
    /// </summary>
    public class HomeRowView
    {
        public string Title { get; }

        public IReadOnlyList<HomeItemView> Contents { get; }

        public HomeRowView(HomeRow row)
        {
            Title = row.Title;
            Contents = (row.Contents ?? new List<HomeItem>())
                .Select(i => new HomeItemView(i))
                .ToList();
        }
    }

    public class HomeItemView : INotifyPropertyChanged
    {
        private readonly HomeItem _item;

        public HomeItemView(HomeItem item)
        {
            _item = item;
        }

        public string Title => _item.Title;
        public string Subtitle => _item.Subtitle;

        public string ThumbnailUrl => Thumbnail.PickUrl(_item.Thumbnails, 544);

        public event PropertyChangedEventHandler PropertyChanged;
    }

    public class PlaylistItemView : INotifyPropertyChanged
    {
        private readonly PlaylistSummary _item;

        public PlaylistItemView(PlaylistSummary item)
        {
            _item = item;
        }

        public string Title => _item.Title;
        public string Count => _item.Count;

        public string ThumbnailUrl => Thumbnail.PickUrl(_item.Thumbnails, 544);

        public event PropertyChangedEventHandler PropertyChanged;
    }

    public class ArtistItemView : INotifyPropertyChanged
    {
        private readonly ArtistSummary _item;

        public ArtistItemView(ArtistSummary item)
        {
            _item = item;
        }

        public string Artist => _item.Artist;
        public string Subscribers => _item.Subscribers;

        public string ThumbnailUrl => Thumbnail.PickUrl(_item.Thumbnails, 320);

        public event PropertyChangedEventHandler PropertyChanged;
    }

    public class AlbumItemView : INotifyPropertyChanged
    {
        private readonly AlbumSummary _item;

        public AlbumItemView(AlbumSummary item)
        {
            _item = item;
        }

        public string Title => _item.Title;
        public string Year => _item.Year;

        public string ThumbnailUrl => Thumbnail.PickUrl(_item.Thumbnails, 544);

        public event PropertyChangedEventHandler PropertyChanged;
    }

    public class TrackItemView : INotifyPropertyChanged
    {
        private readonly Track _item;

        public TrackItemView(Track item)
        {
            _item = item;
        }

        public string Title => _item.Title;
        public string ArtistText => _item.ArtistText;
        public string Duration => _item.Duration;

        public string ThumbnailUrl => Thumbnail.PickUrl(_item.Thumbnails, 120);

        public event PropertyChangedEventHandler PropertyChanged;
    }

    public class SearchResultItemView : INotifyPropertyChanged
    {
        private readonly SearchResultGroup _item;

        public SearchResultItemView(SearchResultGroup item)
        {
            _item = item;
        }

        public string Title => _item.Title;
        public string Artist => _item.Artist;
        public string ResultType => _item.ResultType;

        public string ThumbnailUrl => Thumbnail.PickUrl(_item.Thumbnails, 120);

        public event PropertyChangedEventHandler PropertyChanged;
    }
}
