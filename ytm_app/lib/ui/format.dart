/// Formats a playback position as `m:ss`, or `h:mm:ss` past an hour.
///
/// Unknown durations render as an empty string so callers do not have to invent
/// a placeholder time (spec: do not pretend the value is known).
String formatDuration(Duration? duration) {
  if (duration == null || duration < Duration.zero) return '';

  final int totalSeconds = duration.inSeconds;
  final int hours = totalSeconds ~/ 3600;
  final int minutes = (totalSeconds % 3600) ~/ 60;
  final int seconds = totalSeconds % 60;

  final String paddedSeconds = seconds.toString().padLeft(2, '0');

  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:$paddedSeconds';
  }
  return '$minutes:$paddedSeconds';
}
