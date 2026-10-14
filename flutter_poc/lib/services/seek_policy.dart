/// Seek policy, deliberately pure and free of any plugin import so it is unit
/// testable without an audio device.
///
/// It encodes the rules the shipped WinUI seek bar had to learn the hard way
/// (the P3 seek fix): clamp to the real duration, refuse when the duration is
/// unknown, and never let a negative or past-the-end target reach the engine.
///
/// Returns null when a seek must not happen at all.
Duration? clampSeekTarget(Duration target, Duration duration) {
  if (duration <= Duration.zero) return null; // unknown duration / not started
  if (target < Duration.zero) return Duration.zero;
  if (target > duration) return duration;
  return target;
}
