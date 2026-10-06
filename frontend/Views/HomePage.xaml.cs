using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using System;
using System.Linq;
using System.Threading.Tasks;
using YtMusicClient.Services;

namespace YtMusicClient.Views
{
    /// <summary>
    /// Home: account greeting + a two-column layout built from the real
    /// get_home() rows — a glass hero card (first playable card of the
    /// first row), tile rows in the main column, and the last row as a
    /// narrow rail. All data comes from the real YouTube Music account
    /// via the backend — no mock content.
    /// </summary>
    public sealed partial class HomePage : Page
    {
        public ViewModels.MainShellViewModel ViewModel { get; } = App.ShellViewModel;

        /// <summary>First playable card of the first home row (null if none).</summary>
        public HomeHeroView Hero { get; private set; }

        /// <summary>Last home row, rendered as the right-hand rail (null if only one row).</summary>
        public HomeRowView RailRow { get; private set; }

        private bool _subscribed;
        private bool _loadedOnce;

        public HomePage()
        {
            InitializeComponent();
            Loaded += HomePage_Loaded;
            Unloaded += HomePage_Unloaded;
        }

        private async void HomePage_Loaded(object sender, RoutedEventArgs e)
        {
            if (!_subscribed)
            {
                ViewModel.DataReady += ViewModel_DataReady;
                _subscribed = true;
            }
            await LoadAsync(force: false);
        }

        private void HomePage_Unloaded(object sender, RoutedEventArgs e)
        {
            if (_subscribed)
            {
                ViewModel.DataReady -= ViewModel_DataReady;
                _subscribed = false;
            }
        }

        private void ViewModel_DataReady(object sender, EventArgs e)
        {
            _ = DispatcherQueue.TryEnqueue(async () => await LoadAsync(force: true));
        }

        private async Task LoadAsync(bool force)
        {
            if (!ViewModel.IsLoggedIn)
            {
                SignedOutPanel.Visibility = Visibility.Visible;
                ContentScroll.Visibility = Visibility.Collapsed;
                return;
            }

            SignedOutPanel.Visibility = Visibility.Collapsed;
            if (_loadedOnce && !force)
                return;

            ContentScroll.Visibility = Visibility.Visible;
            LoadingRing.IsActive = true;
            LoadingRing.Visibility = Visibility.Visible;
            ErrorText.Visibility = Visibility.Collapsed;

            try
            {
                var rows = await App.ApiClient.GetHomeAsync();
                var contentRows = rows
                    .Where(r => r.Contents != null && r.Contents.Count > 0)
                    .ToList();
                _loadedOnce = true;

                if (contentRows.Count == 0)
                {
                    ErrorText.Text = "No suggestions available for your account yet.";
                    ErrorText.Visibility = Visibility.Visible;
                    Hero = null;
                    HeroCard.Visibility = Visibility.Collapsed;
                    RailRow = null;
                    RailPanel.Visibility = Visibility.Collapsed;
                    RailColumn.Width = new GridLength(0);
                    HomeRows.ItemsSource = null;
                    RailItems.ItemsSource = null;
                    return;
                }

                // Hero: first playable card of the first row.
                var heroItem = contentRows[0].Contents
                    .FirstOrDefault(i => !string.IsNullOrEmpty(i.VideoId));
                Hero = heroItem != null ? new HomeHeroView(heroItem) : null;
                HeroCard.Visibility = Hero != null ? Visibility.Visible : Visibility.Collapsed;
                if (Hero != null)
                {
                    HeroTitle.Text = Hero.Title;
                    HeroSubtitle.Text = Hero.Subtitle;
                    HeroArt.Background = string.IsNullOrEmpty(Hero.ThumbnailUrl)
                        ? null
                        : new ImageBrush
                        {
                            ImageSource = new BitmapImage(new Uri(Hero.ThumbnailUrl)),
                            Stretch = Stretch.UniformToFill
                        };
                }

                // Rail: the last row, as a narrow vertical list.
                RailRow = contentRows.Count >= 2 ? new HomeRowView(contentRows[^1]) : null;
                RailPanel.Visibility = RailRow != null ? Visibility.Visible : Visibility.Collapsed;
                RailColumn.Width = RailRow != null ? new GridLength(250) : new GridLength(0);
                RailTitle.Text = RailRow?.Title ?? "";
                RailItems.ItemsSource = RailRow?.Contents;

                // Main column: every row except the rail row, with the hero
                // card excluded so it does not appear twice.
                var mainRowCount = contentRows.Count - (RailRow != null ? 1 : 0);
                HomeRows.ItemsSource = contentRows
                    .Take(mainRowCount)
                    .Select(r => new HomeRowView(r, heroItem?.VideoId))
                    .ToList();
            }
            catch (ApiRequestException ex) when (ex.StatusCode == 401)
            {
                ViewModel.IsLoggedIn = false;
                ViewModel.AuthStatusText = "Session expired";
                SignedOutPanel.Visibility = Visibility.Visible;
                ContentScroll.Visibility = Visibility.Collapsed;
            }
            catch (Exception ex)
            {
                ErrorText.Text = "Could not load your recommendations: " + ex.Message;
                ErrorText.Visibility = Visibility.Visible;
            }
            finally
            {
                LoadingRing.IsActive = false;
                LoadingRing.Visibility = Visibility.Collapsed;
            }
        }

        private async void SignInButton_Click(object sender, RoutedEventArgs e)
        {
            if (App.Window is MainWindow mainWindow)
                await mainWindow.StartSignInAsync();
        }

        /// <summary>
        /// Card click: song/video cards (those carry a videoId) start playback;
        /// album/playlist/artist cards keep doing nothing until detail pages exist.
        /// </summary>
        private async void HomeCard_Click(object sender, RoutedEventArgs e)
        {
            if ((sender as FrameworkElement)?.DataContext is not HomeItemView item)
                return;
            if (string.IsNullOrEmpty(item.VideoId))
                return;

            await App.Playback.PlayAsync(item.VideoId, item.Title, item.Subtitle, item.ThumbnailUrl);
            if (App.Window is MainWindow mainWindow)
                mainWindow.ShowNowPlaying();
        }

        /// <summary>Hero banner Play button — plays the hero card.</summary>
        private async void HeroPlay_Click(object sender, RoutedEventArgs e)
        {
            if (Hero == null || string.IsNullOrEmpty(Hero.VideoId))
                return;

            await App.Playback.PlayAsync(Hero.VideoId, Hero.Title, Hero.Subtitle, Hero.ThumbnailUrl);
            if (App.Window is MainWindow mainWindow)
                mainWindow.ShowNowPlaying();
        }
    }
}
