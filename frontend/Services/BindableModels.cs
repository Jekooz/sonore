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

        /// <summary>Backend group label (Songs, Videos, Albums, …) — drives the filter chips.</summary>
        public string Category => _item.Category;

        /// <summary>Song/video id — non-empty means the result can play.</summary>
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
}
