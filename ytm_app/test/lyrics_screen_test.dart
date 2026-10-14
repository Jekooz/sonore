import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
// Riverpod 3 exposes `Override` only through `misc.dart`.
import 'package:riverpod/misc.dart' show Override;
import 'package:ytm_app/audio/track.dart';
import 'package:ytm_app/data/api_client.dart';
import 'package:ytm_app/data/models.dart';
import 'package:ytm_app/data/ytm_repository.dart';
import 'package:ytm_app/features/lyrics/lyrics_controller.dart';
import 'package:ytm_app/ui/screen_states.dart';

import 'support/harness.dart';

/// The sidecar's real `/lyrics/{videoId}` shapes, as the backend produces them.
const String _timedBody = '''
{"videoId":"a","available":true,"synced":true,"source":"Source: Musixmatch",
 "lines":[{"text":"First line","startMs":0,"endMs":1200},
          {"text":"","startMs":1200,"endMs":2400},
          {"text":"Second line","startMs":2400,"endMs":3600}]}
''';

const String _staticBody = '''
{"videoId":"a","available":true,"synced":false,"source":null,
 "lines":[{"text":"Static one"},{"text":"Static two"}]}
''';

YtmRepository repositoryReturning(String body, {int status = 200}) {
  final MockClient client = MockClient((http.Request request) async {
    // Discovery probes /health first; the lyrics body is for the real request
    // only. The payload mirrors test/fixtures/health.json.
    if (request.url.path == '/health') {
      return http.Response(
        '{"status":"ok"}',
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }
    return http.Response(
      body,
      status,
      headers: <String, String>{'content-type': 'application/json'},
    );
  });
  return YtmRepository(
    YtmApiClient(client: client, readPortFile: () async => '8000'),
  );
}

Track get _track => testQueue().first;

void main() {
  group('lyrics data layer', () {
    test('a timed payload becomes real lines with real timings', () async {
      final LyricsResult? result = await repositoryReturning(_timedBody)
          .lyrics(_track);

      expect(result, isNotNull);
      expect(result!.synced, isTrue);
      expect(result.source, 'Source: Musixmatch');
      // The blank line is dropped rather than rendered as an empty row.
      expect(result.lines, hasLength(2));
      expect(result.lines.first.text, 'First line');
      expect(result.lines.first.start, Duration.zero);
      expect(result.lines.last.start, const Duration(milliseconds: 2400));
      expect(result.lines.every((LyricsLine l) => l.isTimed), isTrue);
    });

    test(
      'a static payload keeps its lines untimed rather than inventing any',
      () async {
        final LyricsResult? result = await repositoryReturning(_staticBody)
            .lyrics(_track);

        expect(result!.synced, isFalse);
        expect(result.lines, hasLength(2));
        expect(result.lines.every((LyricsLine l) => !l.isTimed), isTrue);
      },
    );

    test('a 404 means "no lyrics", not an error', () async {
      final LyricsResult? result = await repositoryReturning(
        '{"detail":"No lyrics are available for this track."}',
        status: 404,
      ).lyrics(_track);

      expect(result, isNull);
    });

    test('a malformed 200 does not become fake lyrics', () async {
      final LyricsResult? result = await repositoryReturning(
        '{"videoId":"a","lines":[]}',
      ).lyrics(_track);
      expect(result, isNull);
    });
  });

  group('LyricsScreen states', () {
    Future<void> pumpLyrics(
      WidgetTester tester, {
      required List<Override> extraOverrides,
      List<Track>? queue,
      bool settle = true,
    }) async {
      await pumpAtSize(
        tester,
        appScope(
          initialLocation: '/now-playing/lyrics',
          queue: queue ?? testQueue(),
          extraOverrides: extraOverrides,
        ),
        size: kDesktop,
        settle: settle,
      );
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('shows a skeleton while lyrics load', (
      WidgetTester tester,
    ) async {
      // A never-completing future, not a long delay: the widget-test clock
      // advances as far as a pumpAndSettle wants, so any real timer fires.
      final Completer<LyricsResult?> pending = Completer<LyricsResult?>();
      addTearDown(() {
        if (!pending.isCompleted) pending.complete(null);
      });
      await pumpLyrics(
        tester,
        settle: false,
        extraOverrides: <Override>[
          lyricsProvider.overrideWith((Ref ref) => pending.future),
        ],
      );

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(Skeleton), findsWidgets);
    });

    testWidgets('renders real timed lyrics with their attribution', (
      WidgetTester tester,
    ) async {
      final LyricsResult result = LyricsResult.fromJson(
        await _decode(_timedBody),
      );
      await pumpLyrics(
        tester,
        extraOverrides: <Override>[
          lyricsProvider.overrideWith((Ref ref) async => result),
        ],
      );

      expect(find.text('First line'), findsOneWidget);
      expect(find.text('Second line'), findsOneWidget);
      expect(find.text('Source: Musixmatch'), findsOneWidget);
    });

    testWidgets('static lyrics render as static text with no seek affordance', (
      WidgetTester tester,
    ) async {
      final LyricsResult result = LyricsResult.fromJson(
        await _decode(_staticBody),
      );
      await pumpLyrics(
        tester,
        extraOverrides: <Override>[
          lyricsProvider.overrideWith((Ref ref) async => result),
        ],
      );

      expect(find.text('Static one'), findsOneWidget);
      // Untimed lines are text, not buttons: nothing may offer to seek to a
      // time the provider never supplied.
      final Iterable<Semantics> semantics = tester.widgetList<Semantics>(
        find.byType(Semantics),
      );
      expect(
        semantics.any(
          (Semantics s) =>
              s.properties.label?.startsWith('Go to Static one') ?? false,
        ),
        isFalse,
      );
    });

    testWidgets('timed lines are offered as seek targets', (
      WidgetTester tester,
    ) async {
      final LyricsResult result = LyricsResult.fromJson(
        await _decode(_timedBody),
      );
      await pumpLyrics(
        tester,
        extraOverrides: <Override>[
          lyricsProvider.overrideWith((Ref ref) async => result),
        ],
      );

      final Iterable<Semantics> semantics = tester.widgetList<Semantics>(
        find.byType(Semantics),
      );
      expect(
        semantics.any(
          (Semantics s) => s.properties.label == 'Go to First line',
        ),
        isTrue,
      );
    });

    testWidgets('says plainly when the service has no lyrics', (
      WidgetTester tester,
    ) async {
      await pumpLyrics(
        tester,
        extraOverrides: <Override>[
          lyricsProvider.overrideWith((Ref ref) async => null),
        ],
      );

      expect(find.text('No lyrics for this track.'), findsOneWidget);
      expect(find.textContaining('does not publish lyrics'), findsOneWidget);
    });

    testWidgets('an offline sidecar shows the offline state', (
      WidgetTester tester,
    ) async {
      await pumpLyrics(
        tester,
        extraOverrides: <Override>[
          connectionProvider.overrideWith(
            (Ref ref) async => const YtmConnection(status: YtmStatus.offline),
          ),
          lyricsProvider.overrideWith((Ref ref) async => null),
        ],
      );

      expect(find.text('YouTube Music is not reachable.'), findsOneWidget);
    });

    testWidgets('a failed request shows the failure with a retry', (
      WidgetTester tester,
    ) async {
      await pumpLyrics(
        tester,
        extraOverrides: <Override>[
          lyricsProvider.overrideWith(
            (Ref ref) async =>
                throw const YtmRequestException('Lyrics request failed.'),
          ),
        ],
      );

      expect(find.text('Lyrics request failed.'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('a signed-out session shows the sign-in state', (
      WidgetTester tester,
    ) async {
      await pumpLyrics(
        tester,
        extraOverrides: <Override>[
          connectionProvider.overrideWith(
            (Ref ref) async => const YtmConnection(status: YtmStatus.signedOut),
          ),
          lyricsProvider.overrideWith((Ref ref) async => null),
        ],
      );

      expect(find.textContaining('Not signed in'), findsOneWidget);
    });

    testWidgets('nothing playing explains itself instead of showing an error', (
      WidgetTester tester,
    ) async {
      await pumpAtSize(
        tester,
        appScope(initialLocation: '/now-playing/lyrics'),
        size: kDesktop,
      );
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('Nothing is playing.'), findsOneWidget);
      expect(find.text('Browse library'), findsOneWidget);
    });
  });
}

Future<Map<String, dynamic>> _decode(String body) async =>
    jsonDecode(body) as Map<String, dynamic>;
