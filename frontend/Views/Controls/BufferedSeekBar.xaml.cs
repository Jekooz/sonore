using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;

namespace YtMusicClient.Views.Controls
{
    /// <summary>
    /// The single seek bar: played range in accent, buffered range in a muted
    /// lighter fill, drag preview without committing, commit on release. Byte
    /// counts are never shown — the buffered segment is the progress language.
    /// The drag preview updates the time text via <see cref="PreviewSeconds"/>
    /// so the caller can show "1:23" next to the thumb while dragging.
    /// </summary>
    public sealed partial class BufferedSeekBar : UserControl
    {
        /// <summary>Fires once on release with the chosen position in seconds.</summary>
        public event EventHandler<double> SeekRequested;

        /// <summary>True between pointer-down and release; callers suspend their
        /// position timer so it cannot fight the thumb.</summary>
        public bool IsDragging { get; private set; }

        /// <summary>Current thumb position in seconds while dragging (or -1).</summary>
        public double PreviewSeconds { get; private set; } = -1;

        private double _durationSeconds;
        private double _positionSeconds;
        private double _bufferedFraction;

        public BufferedSeekBar()
        {
            InitializeComponent();
        }

        /// <summary>Push the current state; call at ~2-4 Hz, not per frame.</summary>
        public void Update(double durationSeconds, double positionSeconds, double bufferedFraction)
        {
            _durationSeconds = Math.Max(0, durationSeconds);
            if (!IsDragging)
                _positionSeconds = Math.Clamp(positionSeconds, 0, _durationSeconds);
            _bufferedFraction = Math.Clamp(bufferedFraction, 0, 1);
            Render();
        }

        private void Render()
        {
            double width = ActualWidth;
            if (width <= 0)
                return;

            double playedFraction = _durationSeconds > 0 ? _positionSeconds / _durationSeconds : 0;
            playedFraction = Math.Clamp(playedFraction, 0, 1);
            double bufferedEnd = Math.Max(playedFraction, _bufferedFraction);

            PlayedRect.Width = playedFraction * width;
            BufferedRect.Width = bufferedEnd * width;
            SetThumb((IsDragging ? PreviewSeconds : _positionSeconds) / Math.Max(_durationSeconds, 1));
        }

        private void SetThumb(double fraction)
        {
            double width = ActualWidth;
            if (width <= 0) return;
            fraction = Math.Clamp(fraction, 0, 1);
            Thumb.Margin = new Thickness(fraction * width - 6, 0, 0, 0);
        }

        private double FractionFromPointer(Point p)
        {
            double fraction = Math.Clamp(p.X / Math.Max(ActualWidth, 1), 0, 1);
            return fraction;
        }

        private void Root_PointerPressed(object sender, PointerRoutedEventArgs e)
        {
            IsDragging = true;
            PreviewSeconds = 0;
            Root.CapturePointer(e.Pointer);
            MovePreview(e);
        }

        private void Root_PointerMoved(object sender, PointerRoutedEventArgs e)
        {
            if (!IsDragging) return;
            MovePreview(e);
        }

        private void MovePreview(PointerRoutedEventArgs e)
        {
            Point p = e.GetCurrentPoint(Root).Position;
            PreviewSeconds = FractionFromPointer(p) * _durationSeconds;
            SetThumb(FractionFromPointer(p));
            PreviewChanged?.Invoke(this, PreviewSeconds);
        }

        /// <summary>Fires while dragging with the preview time in seconds.</summary>
        public event EventHandler<double> PreviewChanged;

        private void Root_PointerReleased(object sender, PointerRoutedEventArgs e)
        {
            if (!IsDragging) return;
            Root.ReleasePointerCapture(e.Pointer);
            double target = PreviewSeconds;
            IsDragging = false;
            PreviewSeconds = -1;
            SeekRequested?.Invoke(this, target);
        }

        private void Root_PointerCaptureLost(object sender, PointerRoutedEventArgs e)
        {
            // Treat a lost capture (alt-tab, system gesture) as a cancel, not a seek.
            IsDragging = false;
            PreviewSeconds = -1;
            Render();
        }
    }
}
