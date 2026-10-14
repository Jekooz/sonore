import 'package:flutter/foundation.dart';

import '../models/track.dart';

/// Pure index arithmetic, kept out of the notifier so it is unit-testable.
/// Both return null rather than inventing a track, which is the rule the
/// shipped app enforces for Ctrl+Left/Right on an empty queue.
int? nextIndex(int index, int length) =>
    (index >= 0 && index + 1 < length) ? index + 1 : null;

int? previousIndex(int index, int length) =>
    (index > 0 && index < length) ? index - 1 : null;

/// Owns the play order. It lives above the navigator (created once in main()),
/// so the queue survives screen changes — design.md section 5, item 5.
class QueueService extends ChangeNotifier {
  final List<Track> _tracks = <Track>[];
  int _index = -1;

  List<Track> get tracks => List.unmodifiable(_tracks);
  int get index => _index;

  Track? get current =>
      (_index >= 0 && _index < _tracks.length) ? _tracks[_index] : null;

  bool get hasNext => nextIndex(_index, _tracks.length) != null;
  bool get hasPrevious => previousIndex(_index, _tracks.length) != null;

  /// Replace the queue and point at [startAt] (a visible-result click in the
  /// WinUI client does the same thing).
  void replaceAll(List<Track> tracks, {int startAt = 0}) {
    _tracks
      ..clear()
      ..addAll(tracks);
    _index = _tracks.isEmpty ? -1 : startAt.clamp(0, _tracks.length - 1);
    notifyListeners();
  }

  Track? next() {
    final i = nextIndex(_index, _tracks.length);
    if (i == null) return null;
    _index = i;
    notifyListeners();
    return current;
  }

  Track? previous() {
    final i = previousIndex(_index, _tracks.length);
    if (i == null) return null;
    _index = i;
    notifyListeners();
    return current;
  }

  void clear() {
    _tracks.clear();
    _index = -1;
    notifyListeners();
  }
}
