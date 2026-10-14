using System;

namespace YtMusicClient.Views.Controls
{
    /// <summary>
    /// The pointer-drag state machine behind <see cref="BufferedSeekBar"/>,
    /// deliberately free of any UI type so the regression tests can exercise the
    /// exact production code without a live XAML thread. It owns four things:
    /// press/move/release/cancel, the tick-vs-drag arbitration (periodic
    /// playback-position updates must never move the thumb while the user is
    /// dragging), the unknown-duration rule (no drag starts before the stream
    /// reports its length), and the release-target policy (always clamped to
    /// [0, duration]; NaN means "do not commit").
    ///
    /// Regression this encodes: the old control read its preview AFTER
    /// releasing pointer capture, and the synchronous PointerCaptureLost had
    /// already reset it to -1 — so every click/drag committed SeekRequested(-1),
    /// NAudio threw "Position cannot be less than 0", and no user seek ever
    /// reached the audio.
    /// </summary>
    public sealed class SeekDragState
    {
        /// <summary>Preview sentinel: no drag in progress.</summary>
        public const double IdlePreview = -1;

        public bool IsDragging { get; private set; }

        /// <summary>Current thumb position in seconds while dragging, else <see cref="IdlePreview"/>.</summary>
        public double PreviewSeconds { get; private set; } = IdlePreview;

        /// <summary>Last known track duration (0 = unknown).</summary>
        public double DurationSeconds { get; private set; }

        /// <summary>Last committed playback position (ticks apply only while idle).</summary>
        public double PositionSeconds { get; private set; }

        /// <summary>Duration flows in from every update tick, even mid-session.</summary>
        public void SetDuration(double seconds)
            => DurationSeconds = double.IsNaN(seconds) || seconds < 0 ? 0 : seconds;

        /// <summary>
        /// Open a drag. Returns false while the duration is unknown (stream
        /// still starting): seeking is undefined then, so no drag may start and
        /// a click during startup commits nothing.
        /// </summary>
        public bool Press()
        {
            if (DurationSeconds <= 0)
                return false;
            IsDragging = true;
            PreviewSeconds = 0;
            return true;
        }

        /// <summary>Track the pointer's horizontal fraction (0..1) as a preview time.</summary>
        public void Move(double fraction)
        {
            if (!IsDragging || double.IsNaN(fraction))
                return;
            PreviewSeconds = Math.Clamp(fraction, 0, 1) * DurationSeconds;
        }

        /// <summary>
        /// Settle an open drag: returns the clamped commit target, or NaN when
        /// nothing may be committed. State settles atomically here — a later
        /// capture release can no longer observe (or destroy) the preview.
        /// </summary>
        public double Release()
        {
            if (!IsDragging)
                return double.NaN;
            double target = ResolveReleaseTarget(DurationSeconds, PreviewSeconds);
            IsDragging = false;
            PreviewSeconds = IdlePreview;
            return target;
        }

        /// <summary>Abort an open drag (capture lost / pointer canceled). No-op when idle.</summary>
        public void Cancel()
        {
            if (!IsDragging)
                return;
            IsDragging = false;
            PreviewSeconds = IdlePreview;
        }

        /// <summary>
        /// Periodic playback-position tick: applies only while idle — a dragging
        /// thumb is owned by the user, never overwritten by the position timer.
        /// </summary>
        public void ApplyTick(double positionSeconds)
        {
            if (IsDragging || double.IsNaN(positionSeconds))
                return;
            if (DurationSeconds > 0)
                PositionSeconds = Math.Clamp(positionSeconds, 0, DurationSeconds);
            else
                PositionSeconds = positionSeconds < 0 ? 0 : positionSeconds;
        }

        /// <summary>
        /// Pure release policy (pinned by the regression tests): no commit while
        /// the duration is unknown, and the committed time is always clamped to
        /// [0, duration] — a non-finite preview never escapes as a seek request.
        /// Returns <see cref="double.NaN"/> when the release must not fire
        /// <c>SeekRequested</c>.
        /// </summary>
        public static double ResolveReleaseTarget(double durationSeconds, double previewSeconds)
        {
            if (double.IsNaN(durationSeconds) || durationSeconds <= 0)
                return double.NaN;
            if (double.IsNaN(previewSeconds) || double.IsInfinity(previewSeconds))
                return double.NaN;
            return Math.Clamp(previewSeconds, 0, durationSeconds);
        }
    }
}
