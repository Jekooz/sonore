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
    ///
    /// All interaction policy lives in the UI-free <see cref="SeekDragState"/>
    /// (press/move/release/cancel, tick-vs-drag arbitration, clamped commit) so
    /// the regression tests exercise the exact production logic without a live
    /// XAML thread; this class only translates pointers to fractions and back.
    /// </summary>
    public sealed partial class BufferedSeekBar : UserControl
    {
        /// <summary>Fires once on release with the chosen position in seconds.</summary>
        public event EventHandler<double> SeekRequested;

        /// <summary>Fires while dragging with the preview time in seconds.</summary>
        public event EventHandler<double> PreviewChanged;

        private readonly SeekDragState _state = new SeekDragState();
        private double _bufferedFraction;

        /// <summary>True between pointer-down and release; callers suspend their
        /// position timer so it cannot fight the thumb.</summary>
        public bool IsDragging => _state.IsDragging;

        /// <summary>Current thumb position in seconds while dragging (or -1).</summary>
        public double PreviewSeconds => _state.PreviewSeconds;

        public BufferedSeekBar()
        {
            InitializeComponent();
        }

        /// <summary>Push the current state; call at ~2-4 Hz, not per frame.</summary>
        public void Update(double durationSeconds, double positionSeconds, double bufferedFraction)
        {
            _state.SetDuration(durationSeconds);
            _state.ApplyTick(positionSeconds);   // ignored by the state while dragging
            _bufferedFraction = Math.Clamp(bufferedFraction, 0, 1);
            Render();
        }

        private void Render()
        {
            double width = ActualWidth;
            if (width <= 0)
                return;

            double duration = _state.DurationSeconds;
            double playedFraction = duration > 0 ? _state.PositionSeconds / duration : 0;
            playedFraction = Math.Clamp(playedFraction, 0, 1);
            double bufferedEnd = Math.Max(playedFraction, _bufferedFraction);

            PlayedRect.Width = playedFraction * width;
            BufferedRect.Width = bufferedEnd * width;
            double thumbSeconds = _state.IsDragging ? _state.PreviewSeconds : _state.PositionSeconds;
            SetThumb(duration > 0 ? thumbSeconds / duration : 0);
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
            // Press refuses while the duration is unknown (stream starting):
            // seeking is undefined, so a click during startup commits nothing.
            if (!_state.Press())
                return;
            Root.CapturePointer(e.Pointer);
            MovePreview(e);
        }

        private void Root_PointerMoved(object sender, PointerRoutedEventArgs e)
        {
            if (!_state.IsDragging) return;
            MovePreview(e);
        }

        private void MovePreview(PointerRoutedEventArgs e)
        {
            Point p = e.GetCurrentPoint(Root).Position;
            _state.Move(FractionFromPointer(p));
            Render();
            PreviewChanged?.Invoke(this, _state.PreviewSeconds);
        }

        private void Root_PointerReleased(object sender, PointerRoutedEventArgs e)
        {
            if (!_state.IsDragging) return;
            // The state settles the drag (and snapshots the clamped target)
            // BEFORE capture is released: ReleasePointerCapture raises
            // PointerCaptureLost synchronously, and the old control read its
            // preview after that reset it — committing -1 on every click.
            double target = _state.Release();
            Root.ReleasePointerCapture(e.Pointer);
            if (!double.IsNaN(target))
                SeekRequested?.Invoke(this, target);
            else
                Render(); // unknown duration / bad preview: cancel cleanly, keep the drawn position
        }

        private void Root_PointerCaptureLost(object sender, PointerRoutedEventArgs e)
        {
            // A lost capture (alt-tab, system gesture, pointer cancel) is a
            // cancel, not a seek — but only while a drag is genuinely open.
            // The release path settles first, so the capture-lost it triggers
            // is a no-op.
            if (!_state.IsDragging) return;
            _state.Cancel();
            Render();
        }
    }
}
