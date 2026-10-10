using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Animation;

namespace YtMusicClient.Services
{
    /// <summary>
    /// Small, shared motion helpers so every fade uses the same short, eased
    /// timing instead of each screen hand-rolling its own Storyboard. These
    /// animate opacity (a compositor-friendly property), so they stay smooth
    /// even while the audio engine is decoding.
    /// </summary>
    internal static class Motion
    {
        /// <summary>Fade an element from one opacity to another with the standard ease-out.</summary>
        public static void Fade(UIElement element, double from, double to, double seconds)
        {
            if (element == null)
                return;

            element.Opacity = from;
            var storyboard = CreateOpacity(element, from, to, seconds);
            storyboard.Begin();
        }

        /// <summary>Fade an element out, then run <paramref name="onCompleted"/>.</summary>
        public static void FadeOut(UIElement element, double seconds, Action onCompleted)
        {
            if (element == null)
            {
                onCompleted?.Invoke();
                return;
            }

            var storyboard = CreateOpacity(element, null, 0, seconds);
            if (onCompleted != null)
                storyboard.Completed += (s, e) => onCompleted();
            storyboard.Begin();
        }

        private static Storyboard CreateOpacity(UIElement element, double? from, double to, double seconds)
        {
            var animation = new DoubleAnimation
            {
                To = to,
                Duration = new Duration(TimeSpan.FromSeconds(seconds)),
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
            };
            if (from.HasValue)
                animation.From = from.Value;

            Storyboard.SetTarget(animation, element);
            Storyboard.SetTargetProperty(animation, "Opacity");

            var storyboard = new Storyboard();
            storyboard.Children.Add(animation);
            return storyboard;
        }
    }
}
