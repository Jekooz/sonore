import 'package:flutter_test/flutter_test.dart';
import 'package:ytm_poc/models/track.dart';
import 'package:ytm_poc/services/queue_service.dart';
import 'package:ytm_poc/services/seek_policy.dart';
import 'package:ytm_poc/theme/tokens.dart';

void main() {
  group('clampSeekTarget (seek bounds)', () {
    test('passes a target inside the track through unchanged', () {
      expect(
        clampSeekTarget(const Duration(seconds: 30), const Duration(seconds: 200)),
        const Duration(seconds: 30),
      );
    });

    test('clamps to the end of the track', () {
      expect(
        clampSeekTarget(const Duration(seconds: 999), const Duration(seconds: 200)),
        const Duration(seconds: 200),
      );
    });

    test('never lets a negative target reach the engine', () {
      expect(
        clampSeekTarget(const Duration(seconds: -5), const Duration(seconds: 200)),
        Duration.zero,
      );
    });

    test('refuses to seek while the duration is unknown', () {
      expect(clampSeekTarget(const Duration(seconds: 12), Duration.zero), isNull);
      expect(clampSeekTarget(const Duration(seconds: 12), const Duration(seconds: -1)), isNull);
    });
  });

  group('queue index arithmetic (must not invent tracks)', () {
    test('next stops at the end of the queue', () {
      expect(nextIndex(0, 3), 1);
      expect(nextIndex(2, 3), isNull);
      expect(nextIndex(-1, 0), isNull);
    });

    test('previous stops at the start of the queue', () {
      expect(previousIndex(2, 3), 1);
      expect(previousIndex(0, 3), isNull);
      expect(previousIndex(-1, 3), isNull);
    });
  });

  group('QueueService', () {
    Track t(int i) => Track(videoId: 'id$i', title: 'title $i', artist: 'artist');

    test('replaceAll points at the clicked row', () {
      final q = QueueService();
      q.replaceAll([t(1), t(2), t(3)], startAt: 2);
      expect(q.current!.videoId, 'id3');
      expect(q.index, 2);
      expect(q.hasNext, isFalse);
      expect(q.hasPrevious, isTrue);
    });

    test('next/previous walk the queue and refuse past the ends', () {
      final q = QueueService();
      q.replaceAll([t(1), t(2)], startAt: 0);
      expect(q.previous(), isNull); // nothing before the first track
      expect(q.next()!.videoId, 'id2');
      expect(q.next(), isNull); // nothing after the last track
      expect(q.previous()!.videoId, 'id1');
      q.dispose();
    });

    test('an empty queue can never produce a track', () {
      final q = QueueService();
      q.replaceAll(const []);
      expect(q.current, isNull);
      expect(q.next(), isNull);
      expect(q.previous(), isNull);
      q.dispose();
    });
  });

  group('Track.fromSearchResult', () {
    test('reads the artists[] credit line that ytmusicapi uses for songs', () {
      final track = Track.fromSearchResult(const {
        'videoId': 'abc123XYZ',
        'title': 'Maria Maria',
        'resultType': 'song',
        'artists': [
          {'name': 'Santana', 'id': 'UC1'},
          {'name': 'The Product G&B', 'id': 'UC2'},
        ],
      });
      expect(track!.videoId, 'abc123XYZ');
      expect(track.artist, 'Santana, The Product G&B');
    });

    test('falls back to artist then author', () {
      expect(
        Track.fromSearchResult(const {'videoId': 'x1', 'title': 'A', 'artist': 'Solo'})!.artist,
        'Solo',
      );
      expect(
        Track.fromSearchResult(const {'videoId': 'x2', 'title': 'B', 'author': 'Curator'})!.artist,
        'Curator',
      );
    });

    test('returns null for rows with no playable id', () {
      expect(Track.fromSearchResult(const {'title': 'Album row', 'browseId': 'MPREb_1'}), isNull);
      expect(Track.fromSearchResult(const {'videoId': '', 'title': 'Empty id'}), isNull);
    });
  });

  group('formatDuration', () {
    test('formats mm:ss and clamps negatives', () {
      expect(formatDuration(const Duration(minutes: 3, seconds: 7)), '3:07');
      expect(formatDuration(Duration.zero), '0:00');
      expect(formatDuration(const Duration(seconds: -9)), '0:00');
    });
  });
}
