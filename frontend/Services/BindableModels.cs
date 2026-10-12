using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;

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

        /// <param name="excludeVideoId">
        /// Skip the card with this videoId, so the hero card does not
        /// also appear in its own row's tile strip.
        /// </param>
        public HomeRowView(HomeRow row, string excludeVideoId = null)
        {
            Title = row.Title;
            var items = row.Contents ?? new List<HomeItem>();
            if (!string.IsNullOrEmpty(excludeVideoId))
                items = items.Where(i => i.VideoId != excludeVideoId).ToList();
            Contents = items
                .Select(i => new HomeItemView(i))
                .ToList();
        }
    }

    /// <summary>
    /// The hero banner: the first playable card of the first home row,
    /// shown large in a glass card. All fields come from the real
    /// row data — nothing is synthesized.
    /// </summary>
    public class HomeHeroView
    {
        private readonly HomeItem _item;

        public HomeHeroView(HomeItem item)
        {
            _item = item;
        }

        public string Title => _item.Title;
        public string Subtitle => _item.Subtitle;

        /// <summary>Non-empty for playable cards (hero is always one).</summary>
        public string VideoId => _item.VideoId;

        public string ThumbnailUrl => Thumbnail.PickUrl(_item.Thumbnails, 544);

        /// <summary>ImageSource-typed art for x:Bind — null when absent. Binding a
        /// string to ImageSource crashes on null/"" (XamlBindingHelper.ConvertValue
        /// throws E_INVALIDARG), so templates must bind this instead.</summary>
        public ImageSource ThumbnailImage
        {
            get
            {
                var url = ThumbnailUrl;
                return string.IsNullOrEmpty(url) ? null : new BitmapImage(new Uri(url));
            }
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

        /// <summary>Present on song/video cards — non-empty means the card can play.</summary>
        public string VideoId => _item.VideoId;

        /// <summary>Album id (MPREb_…) — set on album cards, which play as a collection.</summary>
        public string BrowseId => _item.BrowseId;

        /// <summary>Playlist id — set on playlist cards, which play as a collection.</summary>
        public string PlaylistId => _item.PlaylistId;

        public string ThumbnailUrl => Thumbnail.PickUrl(_item.Thumbnails, 544);

        /// <summary>ImageSource-typed art for x:Bind — null when absent. Binding a
        /// string to ImageSource crashes on null/"" (XamlBindingHelper.ConvertValue
        /// throws E_INVALIDARG), so templates must bind this instead.</summary>
        public ImageSource ThumbnailImage
        {
            get
            {
                var url = ThumbnailUrl;
                return string.IsNullOrEmpty(url) ? null : new BitmapImage(new Uri(url));
            }
        }

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
        public string Author => _item.Author;
        public bool HasAuthor => !string.IsNullOrWhiteSpace(Author);
        public Microsoft.UI.Xaml.Visibility AuthorVisibility => HasAuthor ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;

        /// <summary>Real playlist id — lets a playlist card resolve its tracks.</summary>
        public string PlaylistId => _item.PlaylistId;

        public string ThumbnailUrl => Thumbnail.PickUrl(_item.Thumbnails, 544);

        /// <summary>ImageSource-typed art for x:Bind — null when absent. Binding a
        /// string to ImageSource crashes on null/"" (XamlBindingHelper.ConvertValue
        /// throws E_INVALIDARG), so templates must bind this instead.</summary>
        public ImageSource ThumbnailImage
        {
            get
            {
                var url = ThumbnailUrl;
                return string.IsNullOrEmpty(url) ? null : new BitmapImage(new Uri(url));
            }
        }

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

        /// <summary>Real channel id (UC…) — lets an artist card open their tracklist.</summary>
        public string BrowseId => _item.BrowseId;

        public string ThumbnailUrl => Thumbnail.PickUrl(_item.Thumbnails, 320);

        /// <summary>ImageSource-typed art for x:Bind — null when absent. Binding a
        /// string to ImageSource crashes on null/"" (XamlBindingHelper.ConvertValue
        /// throws E_INVALIDARG), so templates must bind this instead.</summary>
        public ImageSource ThumbnailImage
        {
            get
            {
                var url = ThumbnailUrl;
                return string.IsNullOrEmpty(url) ? null : new BitmapImage(new Uri(url));
            }
        }

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

        /// <summary>Real album id (MPREb_…) — lets an album card resolve its tracks.</summary>
        public string BrowseId => _item.BrowseId;

        public string ThumbnailUrl => Thumbnail.PickUrl(_item.Thumbnails, 544);

        /// <summary>ImageSource-typed art for x:Bind — null when absent. Binding a
        /// string to ImageSource crashes on null/"" (XamlBindingHelper.ConvertValue
        /// throws E_INVALIDARG), so templates must bind this instead.</summary>
        public ImageSource ThumbnailImage
        {
            get
            {
                var url = ThumbnailUrl;
                return string.IsNullOrEmpty(url) ? null : new BitmapImage(new Uri(url));
            }
        }

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

        /// <summary>Song id — non-empty means the row can play.</summary>
        public string VideoId => _item.VideoId;

        public string ThumbnailUrl => Thumbnail.PickUrl(_item.Thumbnails, 120);

        /// <summary>ImageSource-typed art for x:Bind — null when absent. Binding a
        /// string to ImageSource crashes on null/"" (XamlBindingHelper.ConvertValue
        /// throws E_INVALIDARG), so templates must bind this instead.</summary>
        public ImageSource ThumbnailImage
        {
            get
            {
                var url = ThumbnailUrl;
                return string.IsNullOrEmpty(url) ? null : new BitmapImage(new Uri(url));
            }
        }

        public event PropertyChangedEventHandler PropertyChanged;
    }

    /// <summary>
    /// One row of a collection (album / playlist / artist) tracklist. Carries the
    /// row number plus the real track fields, so the row can render its index and
    /// play itself without re-looking-up anything from the collection.
    /// </summary>
    public class CollectionTrackView : INotifyPropertyChanged
    {
        private readonly Track _item;

        public CollectionTrackView(Track item, int index)
        {
            _item = item;
            Index = index;
        }

        /// <summary>Zero-based position in the collection — playing a row uses this.</summary>
        public int Index { get; }

        /// <summary>1-based label shown in the tracklist gutter.</summary>
        public string Number => (Index + 1).ToString();

        public string Title => _item.Title;
        public string ArtistText => _item.ArtistText;
        public string Duration => _item.Duration;

        /// <summary>Song id — non-empty means the row can play.</summary>
        public string VideoId => _item.VideoId;

        public string ThumbnailUrl => Thumbnail.PickUrl(_item.Thumbnails, 120);

        /// <summary>ImageSource-typed art for x:Bind — null when absent. Binding a
        /// string to ImageSource crashes on null/"" (XamlBindingHelper.ConvertValue
        /// throws E_INVALIDARG), so templates must bind this instead.</summary>
        public ImageSource ThumbnailImage
        {
            get
            {
                var url = ThumbnailUrl;
                return string.IsNullOrEmpty(url) ? null : new BitmapImage(new Uri(url));
            }
        }

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
        public string ResultType => _item.ResultType;

        /// <summary>Normalized credit line (artist(s)/author) — see SearchResultGroup.CreditText.</summary>
        public string Artist => _item.CreditText;

        /// <summary>Duration string (e.g. 4:19) — null when the result has none.</summary>
        public string Duration => _item.Duration;

        /// <summary>Artist credit + secondary info (views / song count) in one line.</summary>
        public string SubText
        {
            get
            {
                var artist = _item.CreditText;
                var info = _item.InfoText;
                if (!string.IsNullOrEmpty(artist) && !string.IsNullOrEmpty(info))
                    return artist + "  \u2022  " + info;
                return artist ?? info ?? "";
            }
        }

        /// <summary>Backend group label (Songs, Videos, Albums, …) — drives the filter chips.</summary>
        public string Category => _item.Category;

        /// <summary>Song/video id — non-empty means the result can play.</summary>
        public string VideoId => _item.VideoId;

        /// <summary>Album id / playlist id — set on album/playlist results.</summary>
        public string BrowseId => _item.BrowseId;
        public string PlaylistId => _item.PlaylistId;

        public string ThumbnailUrl => Thumbnail.PickUrl(_item.Thumbnails, 120);

        /// <summary>ImageSource-typed art for x:Bind — null when absent. Binding a
        /// string to ImageSource crashes on null/"" (XamlBindingHelper.ConvertValue
        /// throws E_INVALIDARG), so templates must bind this instead.</summary>
        public ImageSource ThumbnailImage
        {
            get
            {
                var url = ThumbnailUrl;
                return string.IsNullOrEmpty(url) ? null : new BitmapImage(new Uri(url));
            }
        }

        public event PropertyChangedEventHandler PropertyChanged;
    }
}
