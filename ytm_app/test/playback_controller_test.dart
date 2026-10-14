import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:ytm_app/audio/playback_controller.dart';
import 'package:ytm_app/audio/playback_state.dart';
import 'package:ytm_app/audio/track.dart';
import 'package:ytm_app/core/app_settings.dart';
import 'package:ytm_app/theme/tokens.dart';

import 'support/harness.dart';

late ProviderContainer container;
late PlaybackController controller;

PlaybackState get state => container.read(playbackProvider);

void main() {
  setUp(() {
    container = ProviderContainer();
    controller = container.read(playbackProvider.notifier);
  });

  tearDown(() => container.dispose());

  test('starts empty', () {
    expect(state.hasTrack, isFalse);
    expect(state.current, isNull);
    expect(state.upNext, isEmpty);
    expect(state.canSeek, isFalse);
  });

  test('setQueue loads the queue and starts playing', () {
    controller.setQueue(testQueue());
    expect(state.hasTrack, isTrue);
    expect(state.current!.title, 'Falling For You');
    expect(state.isPlaying, isTrue);
    expect(state.upNext.length, 2);
  });

  test('setQueue with an empty list clears the player', () {
    controller.setQueue(testQueue());
    controller.setQueue(const <Track>[]);
    expect(state.hasTrack, isFalse);
  });

  test('setQueue clamps a start index past the end', () {
    controller.setQueue(testQueue(), startIndex: 99);
    expect(state.index, testQueue().length - 1);
  });

  test('next advances through the queue', () {
    controller.setQueue(testQueue());
    controller.next();
    expect(state.current!.title, 'Midnight Drive');
    controller.next();
    expect(state.current!.title, 'Paper Boats');
  });

  test('next stops at the end when repeat is off', () {
    controller.setQueue(testQueue(), startIndex: 2);
    controller.next();
    expect(state.index, 2);
    expect(state.isPlaying, isFalse);
    expect(state.position, Duration.zero);
  });

  test('next wraps when repeat all is on', () {
    controller.setQueue(testQueue(), startIndex: 2);
    controller.cycleRepeat();
    expect(state.repeat, RepeatMode.all);
    controller.next();
    expect(state.index, 0);
    expect(state.isPlaying, isTrue);
  });

  test('repeat cycles off to all to one to off', () {
    expect(state.repeat, RepeatMode.off);
    controller.cycleRepeat();
    expect(state.repeat, RepeatMode.all);
    controller.cycleRepeat();
    expect(state.repeat, RepeatMode.one);
    controller.cycleRepeat();
    expect(state.repeat, RepeatMode.off);
  });

  test('next replays the same track when repeat one is on', () {
    controller.setQueue(testQueue(), startIndex: 1);
    controller.cycleRepeat();
    controller.cycleRepeat();
    expect(state.repeat, RepeatMode.one);
    controller.next();
    expect(state.index, 1);
    expect(state.position, Duration.zero);
    expect(state.isPlaying, isTrue);
  });

  test('previous restarts the track once it is past the threshold', () {
    controller.setQueue(testQueue(), startIndex: 1);
    controller.reportProgress(
      position: Tokens.previousRestartThreshold + const Duration(seconds: 1),
    );
    controller.previous();
    expect(state.index, 1);
    expect(state.position, Duration.zero);
  });

  test('previous steps back when the track has barely started', () {
    controller.setQueue(testQueue(), startIndex: 1);
    controller.reportProgress(position: const Duration(seconds: 1));
    controller.previous();
    expect(state.index, 0);
  });

  test('previous on the first track restarts it', () {
    controller.setQueue(testQueue());
    controller.previous();
    expect(state.index, 0);
    expect(state.position, Duration.zero);
  });

  test('seek clamps to the known duration', () {
    controller.setQueue(testQueue());
    controller.seek(const Duration(hours: 1));
    expect(state.position, state.duration);
    controller.seek(const Duration(seconds: -5));
    expect(state.position, Duration.zero);
  });

  test('seek is ignored when the duration is unknown', () {
    controller.setQueue(const <Track>[
      Track(id: 'x', title: 'Unknown length', artist: 'Nobody'),
    ]);
    expect(state.canSeek, isFalse);
    controller.seek(const Duration(seconds: 30));
    expect(state.position, Duration.zero);
  });

  test('the reported engine duration wins over the metadata duration', () {
    controller.setQueue(testQueue());
    controller.reportProgress(duration: const Duration(minutes: 5));
    expect(state.duration, const Duration(minutes: 5));
  });

  test('toggleLike flips only the current track and persists in the queue', () {
    controller.setQueue(testQueue());
    controller.toggleLike();
    expect(state.current!.isLiked, isTrue);
    expect(state.queue[1].isLiked, isFalse);
    controller.toggleLike();
    expect(state.current!.isLiked, isFalse);
  });

  test('togglePlayPause reflects the real flag', () {
    controller.setQueue(testQueue());
    controller.togglePlayPause();
    expect(state.isPlaying, isFalse);
    controller.togglePlayPause();
    expect(state.isPlaying, isTrue);
  });

  test('playAt ignores out-of-range indices', () {
    controller.setQueue(testQueue());
    controller.playAt(9);
    expect(state.index, 0);
  });

  test('reportError and clearing it', () {
    controller.setQueue(testQueue());
    controller.reportError('Stream failed');
    expect(state.error, 'Stream failed');
    controller.reportError(null);
    expect(state.error, isNull);
  });

  test('shuffle is a persisted toggle', () {
    controller.setShuffle(true);
    expect(state.shuffle, isTrue);
    controller.setQueue(testQueue());
    expect(state.shuffle, isTrue);
  });

  group('shuffle changes play order, not just a flag', () {
    // A deterministic stand-in for the real Fisher-Yates shuffle, so the
    // assertions below are about the controller's behaviour, not about luck.
    ProviderContainer reversedShuffle() => ProviderContainer(
          overrides: <Override>[
            shuffleProvider.overrideWithValue(
              (List<Track> tracks) => tracks.reversed.toList(),
            ),
          ],
        );

    test('turning shuffle on reorders the upcoming tracks', () {
      container.dispose();
      container = reversedShuffle();
      controller = container.read(playbackProvider.notifier);

      controller.setQueue(testQueue());
      controller.setShuffle(true);

      expect(
        state.queue.map((Track t) => t.id).toList(),
        <String>['a', 'c', 'b'],
      );
      // The current track did not move, so turning shuffle on never interrupts
      // what is playing.
      expect(state.current!.id, 'a');

      controller.next();
      expect(state.current!.id, 'c');
    });

    test('turning shuffle off restores the collection order', () {
      container.dispose();
      container = reversedShuffle();
      controller = container.read(playbackProvider.notifier);

      controller.setQueue(testQueue());
      controller.setShuffle(true);
      controller.next();
      expect(state.current!.id, 'c');

      controller.setShuffle(false);

      expect(
        state.queue.map((Track t) => t.id).toList(),
        <String>['a', 'b', 'c'],
      );
      // The same track stays current after the order is restored.
      expect(state.current!.id, 'c');
    });

    test('a queue started while shuffled plays the chosen track first', () {
      container.dispose();
      container = reversedShuffle();
      controller = container.read(playbackProvider.notifier);

      controller.setShuffle(true);
      controller.setQueue(testQueue(), startIndex: 1);

      expect(state.current!.id, 'b');
      expect(state.upNext.map((Track t) => t.id).toList(), <String>['c', 'a']);
    });

    test('editing the queue while shuffled keeps the edited order', () {
      container.dispose();
      container = reversedShuffle();
      controller = container.read(playbackProvider.notifier);

      controller.setQueue(testQueue());
      controller.setShuffle(true);
      controller.removeAt(2);
      controller.setShuffle(false);

      expect(
        state.queue.map((Track t) => t.id).toList(),
        <String>['a', 'c'],
      );
    });

    test('move reorders the queue and carries the current track with it', () {
      controller.setQueue(testQueue(), startIndex: 1);

      controller.move(2, 0);

      expect(
        state.queue.map((Track t) => t.id).toList(),
        <String>['c', 'a', 'b'],
      );
      expect(state.current!.id, 'b');
      expect(state.index, 2);
    });

    test('move ignores a missing source and clamps a far target', () {
      controller.setQueue(testQueue());

      controller.move(-1, 0);
      controller.move(9, 0);
      expect(state.queue.map((Track t) => t.id).toList(), <String>['a', 'b', 'c']);

      // A target past the end means "to the end", not "do nothing".
      controller.move(0, 99);
      expect(state.queue.map((Track t) => t.id).toList(), <String>['b', 'c', 'a']);
    });
  });

  group('player modes persist through the settings store', () {
    test('shuffle writes through', () {
      controller.setShuffle(true);
      expect(container.read(appSettingsProvider).shuffle, isTrue);
      controller.setShuffle(false);
      expect(container.read(appSettingsProvider).shuffle, isFalse);
    });

    test('repeat writes through', () {
      controller.cycleRepeat();
      expect(
        container.read(appSettingsProvider).repeatMode,
        RepeatMode.all,
      );
    });

    test('autoplay writes through', () {
      controller.setAutoplay(false);
      expect(state.autoplay, isFalse);
      expect(container.read(appSettingsProvider).autoplay, isFalse);
    });

    test('the stored modes seed the player on startup', () {
      container.dispose();
      container = ProviderContainer(
        overrides: <Override>[
          initialAppSettingsProvider.overrideWithValue(
            const AppSettings(
              repeatMode: RepeatMode.one,
              shuffle: true,
              autoplay: false,
            ),
          ),
        ],
      );
      controller = container.read(playbackProvider.notifier);

      expect(state.repeat, RepeatMode.one);
      expect(state.shuffle, isTrue);
      expect(state.autoplay, isFalse);
    });

    test('a settings reset moves the transport too', () {
      container.dispose();
      container = ProviderContainer(
        overrides: <Override>[
          initialAppSettingsProvider.overrideWithValue(
            const AppSettings(repeatMode: RepeatMode.all, autoplay: false),
          ),
        ],
      );
      controller = container.read(playbackProvider.notifier);
      controller.setQueue(testQueue());

      container.read(appSettingsProvider.notifier).resetAll();

      expect(state.repeat, RepeatMode.off);
      expect(state.autoplay, isTrue);
      expect(state.hasTrack, isTrue);
    });
  });
}
