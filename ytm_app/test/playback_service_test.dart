import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ytm_app/audio/listening_event.dart';
import 'package:ytm_app/audio/playback_controller.dart';
import 'package:ytm_app/audio/playback_engine.dart';
import 'package:ytm_app/audio/playback_service.dart';
import 'package:ytm_app/audio/playback_state.dart';
import 'package:ytm_app/audio/track.dart';

import 'support/fake_engine.dart';
import 'support/harness.dart';

/// A resolver failure the UI can show verbatim.
class _TestFailure implements PlaybackFailure {
  _TestFailure(this.message);
  @override
  final String message;
}

late ProviderContainer container;
late FakePlaybackEngine engine;
late PlaybackController controller;

/// Track ids the resolver was asked for, in order.
late List<String> resolved;

/// Tracks the prefetch seam was asked to warm, in order.
late List<String> prefetched;

/// Listening events the service reported, in order.
late List<ListeningEvent> reported;

/// What the Autoplay seam answers with. Empty means "nothing to add".
late List<Track> autoplayResult;

/// The seed/queue the Autoplay seam was asked about, when it was called.
(Track seed, List<String> exclude)? autoplayRequest;

/// When set, the Autoplay seam throws it.
Object? autoplayError;

/// When set, the resolver throws it.
Object? resolveError;

PlaybackState get state => container.read(playbackProvider);

/// Lets the service's asynchronous reconcile finish.
Future<void> settle() => pumpEventQueue();

void main() {
  setUp(() {
    engine = FakePlaybackEngine();
    resolved = <String>[];
    prefetched = <String>[];
    reported = <ListeningEvent>[];
    autoplayResult = <Track>[];
    autoplayRequest = null;
    autoplayError = null;
    resolveError = null;
    container = ProviderContainer(
      overrides: [
        // overrideWith (not overrideWithValue) so the provider still disposes
        // the engine with the container, which the app relies on.
        playbackEngineProvider.overrideWith((Ref ref) {
          ref.onDispose(engine.dispose);
          return engine;
        }),
        streamUrlResolverProvider.overrideWithValue((Track track) async {
          if (resolveError != null) throw resolveError!;
          resolved.add(track.id);
          return 'https://stream.invalid/${track.id}';
        }),
        trackPrefetcherProvider.overrideWithValue((Track track) async {
          prefetched.add(track.id);
        }),
        listeningReporterProvider.overrideWithValue((ListeningEvent event) async {
          reported.add(event);
        }),
        autoplayResolverProvider.overrideWithValue((
          Track seed,
          List<String> exclude,
        ) async {
          autoplayRequest = (seed, exclude);
          final Object? error = autoplayError;
          if (error != null) throw error;
          return autoplayResult;
        }),
      ],
    );
    controller = container.read(playbackProvider.notifier);
    // Starting the service is what wires the controller to the engine;
    // the shell does this in the running app.
    container.read(playbackServiceProvider);
  });

  tearDown(() => container.dispose());

  group('load', () {
    test('an empty player never touches the engine', () async {
      await settle();
      expect(engine.commands, isEmpty);
      expect(engine.openedUrls, isEmpty);
    });

    test('setQueue resolves the first track and plays it', () async {
      controller.setQueue(testQueue());
      await settle();

      expect(resolved, <String>['a']);
      expect(engine.openedUrls, <String>['https://stream.invalid/a']);
      expect(engine.commands, <String>['open:play']);
      expect(state.isLoading, isFalse);
    });

    test('selecting another row loads that track', () async {
      controller.setQueue(testQueue());
      await settle();
      controller.playAt(2);
      await settle();

      expect(resolved, <String>['a', 'c']);
      expect(engine.openedUrls.last, 'https://stream.invalid/c');
    });

    test('loading state is on while the stream resolves', () async {
      controller.setQueue(testQueue());
      // Before the microtask completes the UI must be able to show a skeleton.
      expect(state.isLoading, isTrue);
      await settle();
      expect(state.isLoading, isFalse);
    });

    test('a slow load is dropped when the user moves on first', () async {
      // First resolve is held open until we release it.
      final Completer<String> first = Completer<String>();
      container.dispose();
      engine = FakePlaybackEngine();
      resolved = <String>[];
      container = ProviderContainer(
        overrides: [
          playbackEngineProvider.overrideWith((Ref ref) {
            ref.onDispose(engine.dispose);
            return engine;
          }),
          streamUrlResolverProvider.overrideWithValue((Track track) {
            resolved.add(track.id);
            if (track.id == 'a') return first.future;
            return Future<String>.value('https://stream.invalid/${track.id}');
          }),
        ],
      );
      controller = container.read(playbackProvider.notifier);
      container.read(playbackServiceProvider);

      controller.setQueue(testQueue());
      await settle();
      controller.playAt(1); // user picks another track while 'a' is in flight
      await settle();

      // The abandoned load completes late and must not play over the new track.
      first.complete('https://stream.invalid/a-late');
      await settle();

      expect(engine.openedUrls, <String>['https://stream.invalid/b']);
      expect(state.current!.id, 'b');
      expect(state.isLoading, isFalse);
    });

    test('clearing the queue unloads the engine', () async {
      controller.setQueue(testQueue());
      await settle();
      controller.clear();
      await settle();

      expect(engine.commands.last, 'stop');
      expect(state.hasTrack, isFalse);
    });
  });

  group('transport', () {
    test('pause and play are each sent once', () async {
      controller.setQueue(testQueue());
      await settle();
      controller.togglePlayPause();
      await settle();
      controller.togglePlayPause();
      await settle();

      expect(engine.commands, <String>['open:play', 'pause', 'play']);
    });

    test('a committed seek reaches the engine once, clamped', () async {
      controller.setQueue(testQueue());
      await settle();
      controller.seek(const Duration(seconds: 30));
      await settle();

      expect(engine.commands.last, 'seek:30000');
      // A rebuild with unchanged state must not re-send it.
      controller.reportProgress(position: const Duration(seconds: 31));
      await settle();
      expect(engine.commands.where((String c) => c.startsWith('seek')), hasLength(1));
    });

    test('seeking past the end clamps to the duration', () async {
      controller.setQueue(testQueue());
      await settle();
      controller.seek(const Duration(hours: 2));
      await settle();

      expect(engine.commands.last, 'seek:${state.duration.inMilliseconds}');
    });

    test('repeated seeks to the same position are all applied', () async {
      controller.setQueue(testQueue());
      await settle();
      controller.seek(const Duration(seconds: 20));
      await settle();
      controller.seek(const Duration(seconds: 20));
      await settle();

      expect(
        engine.commands.where((String c) => c.startsWith('seek')),
        <String>['seek:20000', 'seek:20000'],
      );
    });

    test('previous restarts the media when past the threshold', () async {
      controller.setQueue(testQueue(), startIndex: 1);
      await settle();
      engine.emitPosition(const Duration(seconds: 40));
      await settle();
      // reportProgress from the engine already moved the position, so previous
      // is the restart branch: a seek to zero on the same media.
      controller.previous();
      await settle();

      expect(engine.commands.last, 'seek:0');
      expect(engine.openedUrls, hasLength(1));
    });
  });

  group('completion', () {
    test('end of media advances to the next track', () async {
      controller.setQueue(testQueue());
      await settle();
      engine.emitEndOfMedia();
      await settle();

      expect(state.current!.id, 'b');
      expect(state.isPlaying, isTrue);
      expect(engine.openedUrls.last, 'https://stream.invalid/b');
    });

    test('repeat one reloads the same track', () async {
      controller.setQueue(testQueue());
      await settle();
      controller.cycleRepeat();
      controller.cycleRepeat();
      expect(state.repeat, RepeatMode.one);
      engine.emitEndOfMedia();
      await settle();

      expect(state.index, 0);
      expect(engine.openedUrls, <String>[
        'https://stream.invalid/a',
        'https://stream.invalid/a',
      ]);
    });

    test('the end of a repeat-off queue stops without loading again', () async {
      controller.setQueue(testQueue(), startIndex: 2);
      await settle();
      engine.emitEndOfMedia();
      await settle();

      expect(state.isPlaying, isFalse);
      expect(engine.openedUrls, hasLength(1));
    });

    test('end of media does not read as a user pause', () async {
      controller.setQueue(testQueue());
      await settle();
      engine.emitEndOfMedia();

      // The engine emits playing=false before completed=true; the service must
      // not mirror that as a pause, or every track change would look stopped.
      expect(state.isPlaying, isTrue);
      await settle();
      expect(state.current!.id, 'b');
      expect(state.isPlaying, isTrue);
    });
  });

  group('engine reports', () {
    test('position, duration and buffer flow into the state', () async {
      controller.setQueue(testQueue());
      await settle();
      engine.emitPosition(const Duration(seconds: 12));
      engine.emitDuration(const Duration(minutes: 4));
      engine.emitBuffer(const Duration(seconds: 30));
      await settle();

      expect(state.position, const Duration(seconds: 12));
      expect(state.duration, const Duration(minutes: 4));
      expect(state.buffered, const Duration(seconds: 30));
    });

    test('a pause from outside the app is mirrored', () async {
      controller.setQueue(testQueue());
      await settle();
      engine.emitPlaying(true);
      await settle();
      engine.emitPlaying(false); // e.g. an OS media key, not completion
      await settle();

      expect(state.isPlaying, isFalse);
    });

    test('an engine error becomes a user-facing message', () async {
      controller.setQueue(testQueue());
      await settle();
      engine.emitError('Failed to open <stream>');
      await settle();

      expect(state.error, 'Playback failed: Failed to open <stream>');
    });

    test('a resolver failure is reported and nothing is opened', () async {
      resolveError = _TestFailure('YouTube Music session expired.');
      controller.setQueue(testQueue());
      await settle();

      expect(state.error, 'YouTube Music session expired.');
      expect(engine.openedUrls, isEmpty);
      expect(state.isLoading, isFalse);
    });

    test('an engine open failure is reported', () async {
      engine.openError = StateError('no audio output device');
      controller.setQueue(testQueue());
      await settle();

      expect(state.error, 'no audio output device');
      expect(state.isLoading, isFalse);
    });

    test('retry re-requests the stream and clears the error', () async {
      resolveError = _TestFailure('temporary failure');
      controller.setQueue(testQueue());
      await settle();
      expect(state.error, 'temporary failure');

      resolveError = null;
      controller.retryLoad();
      await settle();

      expect(state.error, isNull);
      // The failed attempt never resolved a URL, so this is the first success.
      expect(resolved, <String>['a']);
      expect(engine.openedUrls, <String>['https://stream.invalid/a']);
    });

    test('an unknown failure never leaks a URL into the message', () async {
      resolveError = Exception('GET https://x.invalid/videoplayback?key=secret');
      controller.setQueue(testQueue());
      await settle();

      expect(state.error, 'Could not play "Falling For You".');
      expect(state.error, isNot(contains('secret')));
    });
  });

  group('queue edits', () {
    test('play next inserts after the current track and plays it next', () async {
      final List<Track> queue = testQueue();
      controller.setQueue(queue);
      await settle();

      controller.playNext(<Track>[queue[2]]);
      expect(state.queue.map((Track t) => t.id), <String>['a', 'c', 'b', 'c']);

      engine.emitEndOfMedia();
      await settle();
      expect(state.current!.id, 'c');
    });

    test('add to queue appends and keeps playing the current track', () async {
      final List<Track> queue = testQueue();
      controller.setQueue(queue);
      await settle();

      controller.addToQueue(<Track>[queue[1]]);
      await settle();

      expect(state.queue.map((Track t) => t.id), <String>['a', 'b', 'c', 'b']);
      expect(state.current!.id, 'a');
      expect(engine.openedUrls, hasLength(1));
    });

    test('removing the playing track loads the next one', () async {
      controller.setQueue(testQueue());
      await settle();
      controller.removeAt(0);
      await settle();

      expect(state.current!.id, 'b');
      expect(engine.openedUrls.last, 'https://stream.invalid/b');
    });

    test('removing an upcoming track does not interrupt playback', () async {
      controller.setQueue(testQueue());
      await settle();
      controller.removeAt(2);
      await settle();

      expect(state.current!.id, 'a');
      expect(engine.openedUrls, hasLength(1));
      expect(state.queue.map((Track t) => t.id), <String>['a', 'b']);
    });
  });

  group('autoplay', () {
    /// The candidates the sidecar would return for a refill.
    List<Track> moreTracks() => const <Track>[
          Track(
            id: 'r1',
            title: 'Tidal',
            artist: 'Nova',
            duration: Duration(minutes: 3, seconds: 20),
          ),
          Track(id: 'r2', title: 'Static Bloom', artist: 'Kite Club'),
        ];

    test('the end of the queue is refilled and keeps playing', () async {
      autoplayResult = moreTracks();
      controller.setQueue(testQueue(), startIndex: 2);
      await settle();
      engine.emitEndOfMedia();
      await settle();

      // The seed is the track that just ended and the queue is excluded, so a
      // refill cannot hand back what is already playing.
      expect(autoplayRequest?.$1.id, 'c');
      expect(autoplayRequest?.$2, <String>['a', 'b', 'c']);
      expect(state.queue.map((Track t) => t.id), <String>['a', 'b', 'c', 'r1', 'r2']);
      expect(state.current!.id, 'r1');
      expect(state.isPlaying, isTrue);
      expect(engine.openedUrls.last, 'https://stream.invalid/r1');
    });

    test('autoplay off stops at the end of the queue', () async {
      autoplayResult = moreTracks();
      controller.setQueue(testQueue(), startIndex: 2);
      controller.setAutoplay(false);
      await settle();
      engine.emitEndOfMedia();
      await settle();

      expect(autoplayRequest, isNull);
      expect(state.isPlaying, isFalse);
      expect(state.queue.map((Track t) => t.id), <String>['a', 'b', 'c']);
    });

    test('repeat all wraps instead of refilling', () async {
      autoplayResult = moreTracks();
      controller.setQueue(testQueue(), startIndex: 2);
      controller.cycleRepeat();
      expect(state.repeat, RepeatMode.all);
      await settle();
      engine.emitEndOfMedia();
      await settle();

      expect(autoplayRequest, isNull);
      expect(state.current!.id, 'a');
    });

    test('a track in the middle of the queue never triggers a refill', () async {
      autoplayResult = moreTracks();
      controller.setQueue(testQueue());
      await settle();
      engine.emitEndOfMedia();
      await settle();

      expect(autoplayRequest, isNull);
      expect(state.current!.id, 'b');
    });

    test('nothing to add stops playback without inventing a queue', () async {
      autoplayResult = <Track>[];
      controller.setQueue(testQueue(), startIndex: 2);
      await settle();
      engine.emitEndOfMedia();
      await settle();

      expect(autoplayRequest?.$1.id, 'c');
      expect(state.isPlaying, isFalse);
      expect(state.error, isNull);
      expect(state.queue.map((Track t) => t.id), <String>['a', 'b', 'c']);
    });

    test('a failed refill says why instead of looking like a quiet end',
        () async {
      autoplayError = _TestFailure('YouTube Music is not reachable.');
      controller.setQueue(testQueue(), startIndex: 2);
      await settle();
      engine.emitEndOfMedia();
      await settle();

      expect(state.isPlaying, isFalse);
      expect(state.error, 'YouTube Music is not reachable.');
    });
  });

  group('prefetch', () {
    test('the next track is warmed once the current one is half heard',
        () async {
      controller.setQueue(testQueue());
      await settle();
      engine.emitDuration(const Duration(minutes: 4));
      engine.emitPosition(const Duration(seconds: 60));
      await settle();
      expect(prefetched, isEmpty);

      engine.emitPosition(const Duration(seconds: 121));
      await settle();

      expect(prefetched, <String>['b']);
    });

    test('one track is prefetched once, however many ticks arrive', () async {
      controller.setQueue(testQueue());
      await settle();
      engine.emitDuration(const Duration(minutes: 4));
      engine.emitPosition(const Duration(minutes: 3));
      engine.emitPosition(const Duration(minutes: 3, seconds: 30));
      await settle();

      expect(prefetched, <String>['b']);
    });

    test('nothing is prefetched past the last track', () async {
      controller.setQueue(testQueue(), startIndex: 2);
      await settle();
      engine.emitDuration(const Duration(minutes: 4));
      engine.emitPosition(const Duration(minutes: 3));
      await settle();

      expect(prefetched, isEmpty);
    });
  });

  group('listening events', () {
    test('a finished track is reported as completed with real seconds',
        () async {
      controller.setQueue(testQueue());
      await settle();
      engine.emitPosition(const Duration(seconds: 90));
      engine.emitEndOfMedia();
      await settle();

      expect(reported, hasLength(1));
      expect(reported.single.videoId, 'a');
      expect(reported.single.outcome, ListeningOutcome.completed);
      expect(reported.single.listenedSeconds, 90);
      expect(reported.single.durationSeconds, 238);
      expect(reported.single.title, 'Falling For You');
      expect(reported.single.artist, 'Nova');
    });

    test('moving on early is reported as skipped', () async {
      controller.setQueue(testQueue());
      await settle();
      engine.emitPlaying(true);
      engine.emitPosition(const Duration(seconds: 12));
      await settle();
      controller.playAt(2);
      await settle();

      expect(reported, hasLength(1));
      expect(reported.single.videoId, 'a');
      expect(reported.single.outcome, ListeningOutcome.skipped);
      expect(reported.single.listenedSeconds, 12);
    });

    test('clearing the queue is reported as stopped', () async {
      controller.setQueue(testQueue());
      await settle();
      engine.emitPlaying(true);
      engine.emitPosition(const Duration(seconds: 30));
      await settle();
      controller.clear();
      await settle();

      expect(reported, hasLength(1));
      expect(reported.single.videoId, 'a');
      expect(reported.single.outcome, ListeningOutcome.stopped);
    });

    test('a track that never produced audio is not reported', () async {
      controller.setQueue(testQueue());
      await settle();
      controller.playAt(1);
      await settle();

      expect(reported, isEmpty);
    });

    test('the reported JSON is the sidecar\'s own shape', () async {
      const ListeningEvent event = ListeningEvent(
        videoId: 'a',
        outcome: ListeningOutcome.skipped,
        title: 'Falling For You',
        artist: 'Nova',
        listenedSeconds: 12.5,
        durationSeconds: 238,
      );

      expect(event.toJson(), <String, dynamic>{
        'videoId': 'a',
        'outcome': 'skipped',
        'title': 'Falling For You',
        'artist': 'Nova',
        'listenedSeconds': 12.5,
        'durationSeconds': 238,
      });
    });
  });

  group('disposal', () {
    test('disposing the container disposes the engine', () async {
      container.dispose();
      await settle();
      expect(engine.disposed, isTrue);
    });

    test('a disposed service stops listening to the engine', () async {
      final PlaybackService service = container.read(playbackServiceProvider);
      controller.setQueue(testQueue());
      await settle();
      final Duration before = state.position;

      await service.dispose();
      engine.emitPosition(const Duration(seconds: 99));
      await settle();

      expect(state.position, before);
    });
  });

  group('redaction', () {
    test('signed stream URLs are stripped from engine messages', () {
      const String raw =
          'Failed to open https://rr1---sn-x.googlevideo.com/videoplayback?key=SECRET&sig=abc.';
      final String safe = redactStreamUrls(raw);
      // The URL is one whitespace-delimited token, so its trailing period goes
      // with it; what matters is that no part of the signed URL survives.
      expect(safe, 'Failed to open <stream>');
      expect(safe, isNot(contains('SECRET')));
      expect(safe, isNot(contains('googlevideo')));
      expect(safe, isNot(contains('https://')));
    });

    test('plain messages are left readable', () {
      expect(redactStreamUrls('Failed to initialize audio output'),
          'Failed to initialize audio output');
    });
  });
}
