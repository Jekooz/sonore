import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ytm_app/core/sidecar/sidecar_launcher.dart';

import 'support/harness.dart';

/// A launcher that plays back a scripted sequence of results, so the gate's
/// failure and retry paths are deterministic.
class ScriptedLauncher implements SidecarLauncher {
  ScriptedLauncher(this.results);

  final List<SidecarStatus> results;
  int starts = 0;
  int shutdowns = 0;

  @override
  Future<SidecarStatus> start() async {
    final int index = starts < results.length ? starts : results.length - 1;
    starts++;
    return results[index];
  }

  @override
  Future<void> shutdown() async => shutdowns++;
}

/// A launcher that takes its time, like the real one while the service boots.
class SlowLauncher implements SidecarLauncher {
  final Completer<SidecarStatus> completer = Completer<SidecarStatus>();

  @override
  Future<SidecarStatus> start() => completer.future;

  @override
  Future<void> shutdown() async {}
}

void main() {
  setUpAll(loadAppFonts);

  testWidgets('a failed start shows a real error state, and retry recovers',
      (WidgetTester tester) async {
    final ScriptedLauncher launcher = ScriptedLauncher(<SidecarStatus>[
      const SidecarStatus.failed(
        'The local music service (backend/main.py) could not be found.',
      ),
      const SidecarStatus.ready(port: 8081),
    ]);

    await pumpAtSize(
      tester,
      appScope(sidecarLauncher: launcher),
      size: kPhone,
    );

    expect(find.text('The music service could not be started.'), findsOneWidget);
    expect(
      find.text('The local music service (backend/main.py) could not be found.'),
      findsOneWidget,
    );
    expect(find.text('Try again'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(find.text('The music service could not be started.'), findsNothing);
    expect(find.text('Good evening'), findsOneWidget);
    expect(launcher.starts, 2);
  });

  testWidgets('a ready start renders the app unchanged',
      (WidgetTester tester) async {
    final ScriptedLauncher launcher =
        ScriptedLauncher(<SidecarStatus>[const SidecarStatus.ready(port: 8000)]);

    await pumpAtSize(
      tester,
      appScope(sidecarLauncher: launcher),
      size: kPhone,
    );

    expect(find.text('Good evening'), findsOneWidget);
    expect(find.text('The music service could not be started.'), findsNothing);
  });

  testWidgets('the first launch shows a starting state, never an error',
      (WidgetTester tester) async {
    // The service takes a few seconds to come up on a cold start. The app must
    // not probe it before then: the old first screen was the "not reachable"
    // error, which is a dead end on the very first launch.
    final SlowLauncher launcher = SlowLauncher();

    await pumpAtSize(
      tester,
      appScope(sidecarLauncher: launcher),
      size: kPhone,
      settle: false,
    );
    await tester.pump();

    // A calm starting screen, and no error anywhere on it.
    expect(find.text('Starting the music service…'), findsOneWidget);
    expect(find.text('YouTube Music is not reachable.'), findsNothing);
    expect(find.text('The music service could not be started.'), findsNothing);
    // The app is not built yet, so no page has asked for data that is not
    // there yet.
    expect(find.text('Good evening'), findsNothing);

    launcher.completer.complete(const SidecarStatus.ready(port: 8000));
    await tester.pumpAndSettle();

    expect(find.text('Starting the music service…'), findsNothing);
    expect(find.text('Good evening'), findsOneWidget);
  });
}
