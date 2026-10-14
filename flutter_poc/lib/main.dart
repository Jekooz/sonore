import 'package:flutter/material.dart';

import 'models/track.dart';
import 'services/api_client.dart';
import 'services/playback_service.dart';
import 'services/player_controller.dart';
import 'services/queue_service.dart';
import 'theme/tokens.dart';

void main() {
  // The engine is initialised through the playback layer, so no UI file
  // imports the platform audio package (design.md section 4).
  initializePlaybackEngine();
  runApp(const PocApp());
}

/// Owns the three services so they outlive navigation. This is what makes the
/// queue survive screen changes (design.md section 5, item 5).
class PocApp extends StatefulWidget {
  const PocApp({super.key});

  @override
  State<PocApp> createState() => _PocAppState();
}

class _PocAppState extends State<PocApp> {
  final ApiClient _api = ApiClient();
  final QueueService _queue = QueueService();
  final PlaybackService _playback = MediaKitPlaybackService();
  late final PlayerController _controller =
      PlayerController(api: _api, queue: _queue, playback: _playback);

  @override
  void dispose() {
    _playback.dispose();
    _api.dispose();
    _queue.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'YTM Client — Phase 1 POC',
        debugShowCheckedModeBanner: false,
        theme: Tokens.theme(),
        home: HomePage(controller: _controller),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.controller});

  final PlayerController controller;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _query = TextEditingController();
  String _connection = 'connecting to the sidecar…';
  bool _signedIn = false;
  bool _signingIn = false;
  String _browser = 'your browser';
  List<Track> _results = const <Track>[];
  String? _message;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final url = await widget.controller.api.connect();
    if (!mounted) return;
    setState(() => _connection = url == null
        ? 'sidecar not found — start the existing app (or the backend), then Retry'
        : 'connected: $url');
    if (url != null) await _refreshAuth();
  }

  Future<void> _refreshAuth() async {
    final signedIn = await widget.controller.api.isSignedIn();
    final browser =
        signedIn ? _browser : await widget.controller.api.defaultBrowser();
    if (!mounted) return;
    setState(() {
      _signedIn = signedIn;
      _browser = browser;
    });
  }

  /// The safe, platform-appropriate flow design.md section 5 asks for: the
  /// sidecar opens music.youtube.com in the user's real browser and waits for
  /// the extension hand-off. This client never sees cookie material.
  Future<void> _startSignIn() async {
    setState(() {
      _signingIn = true;
      _message = null;
    });
    try {
      await widget.controller.api.startBrowserSignIn();
      for (var i = 0; i < 90; i++) {
        await Future<void>.delayed(const Duration(seconds: 2));
        if (!mounted) return;
        final state = await widget.controller.api.browserSignInState();
        if (state != 'waiting') break;
      }
      await _refreshAuth();
      if (!mounted) return;
      setState(() => _signingIn = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _signingIn = false;
        _message = 'sign-in failed: $e';
      });
    }
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    setState(() => _message = null);
    try {
      final results = await widget.controller.api.search(q, filter: 'songs');
      if (!mounted) return;
      setState(() => _results = results);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _message = e.message);
    }
  }

  Future<void> _play(int index) async {
    final error = await widget.controller.playFromResults(_results, index);
    if (!mounted) return;
    if (error != null) {
      setState(() => _message = error);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => NowPlayingPage(controller: widget.controller),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('YTM Client — POC')),
      body: ListView(
        padding: const EdgeInsets.all(Tokens.s24),
        children: [
          Text(_connection, style: text.bodySmall),
          const SizedBox(height: Tokens.s4),
          Text(
            _signedIn ? 'signed in' : 'not signed in',
            style: text.bodySmall?.copyWith(
              color: _signedIn ? Tokens.accent : Tokens.textSecondary,
            ),
          ),
          const SizedBox(height: Tokens.s12),
          if (!_signedIn)
            FilledButton(
              onPressed: _signingIn ? null : _startSignIn,
              child: Text(_signingIn
                  ? 'waiting for $_browser…'
                  : 'Sign in with $_browser'),
            ),
          if (!_signedIn) ...[
            const SizedBox(height: Tokens.s4),
            Text(
              'Opens music.youtube.com in your browser; the extension hands the '
              'session to the sidecar. No cookies are sent to this app.',
              style: text.labelSmall,
            ),
          ],
          const SizedBox(height: Tokens.s24),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _query,
                  decoration: const InputDecoration(hintText: 'Search songs'),
                  onSubmitted: (_) => _search(),
                ),
              ),
              const SizedBox(width: Tokens.s8),
              FilledButton(onPressed: _search, child: const Text('Search')),
            ],
          ),
          if (_message != null) ...[
            const SizedBox(height: Tokens.s8),
            Text(_message!, style: text.bodySmall?.copyWith(color: Tokens.accent)),
          ],
          const SizedBox(height: Tokens.s16),
          for (var i = 0; i < _results.length; i++)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(_results[i].title, style: text.bodyMedium),
              subtitle: Text(_results[i].artist, style: text.bodySmall),
              trailing: const Icon(Icons.play_arrow),
              onTap: () => _play(i),
            ),
          if (_results.isEmpty)
            Text('Search to load real results from the sidecar.', style: text.labelSmall),
        ],
      ),
    );
  }
}

/// Shows the transport + a real interactive scrubber. The preview/commit split
/// is the contract design.md section 3.E specifies: dragging updates a temporary
/// preview, release commits exactly one seek, and periodic position ticks never
/// fight the thumb.
class NowPlayingPage extends StatefulWidget {
  const NowPlayingPage({super.key, required this.controller});

  final PlayerController controller;

  @override
  State<NowPlayingPage> createState() => _NowPlayingPageState();
}

class _NowPlayingPageState extends State<NowPlayingPage> {
  Duration? _preview; // non-null only while dragging

  Future<void> _commitSeek(double milliseconds) async {
    await widget.controller.seek(Duration(milliseconds: milliseconds.round()));
    if (mounted) setState(() => _preview = null);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final playback = widget.controller.playback;
    final queue = widget.controller.queue;

    return Scaffold(
      appBar: AppBar(title: const Text('Now Playing')),
      body: ListenableBuilder(
        listenable: queue,
        builder: (context, _) {
          final track = queue.current;
          return Padding(
            padding: const EdgeInsets.all(Tokens.s24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(track?.title ?? 'Nothing playing', style: text.titleLarge),
                const SizedBox(height: Tokens.s8),
                Text(track?.artist ?? '', style: text.bodySmall),
                const SizedBox(height: Tokens.s24),
                StreamBuilder<Duration>(
                  stream: playback.durationStream,
                  builder: (context, durationSnapshot) {
                    final duration = durationSnapshot.data ?? playback.duration;
                    return StreamBuilder<Duration>(
                      stream: playback.positionStream,
                      builder: (context, positionSnapshot) {
                        final position = positionSnapshot.data ?? playback.position;
                        final shown = _preview ?? position;
                        final maxMs = duration.inMilliseconds.toDouble();
                        final seekable = playback.canSeek && maxMs > 0;
                        final sliderMax = seekable ? maxMs : 1.0;
                        final sliderValue = seekable
                            ? shown.inMilliseconds
                                .clamp(0, maxMs.toInt())
                                .toDouble()
                            : 0.0;
                        return Column(
                          children: [
                            Slider(
                              min: 0,
                              max: sliderMax,
                              value: sliderValue,
                              onChanged: seekable
                                  ? (v) => setState(() =>
                                      _preview = Duration(milliseconds: v.round()))
                                  : null,
                              onChangeEnd: seekable ? _commitSeek : null,
                            ),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(formatDuration(shown), style: text.labelSmall),
                                Text(formatDuration(duration), style: text.labelSmall),
                              ],
                            ),
                            if (!seekable)
                              Padding(
                                padding: const EdgeInsets.only(top: Tokens.s4),
                                child: Text(
                                  'Seeking is unavailable until the duration is known.',
                                  style: text.labelSmall,
                                ),
                              ),
                          ],
                        );
                      },
                    );
                  },
                ),
                const SizedBox(height: Tokens.s24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      onPressed: widget.controller.previous,
                      icon: const Icon(Icons.skip_previous),
                      iconSize: 32,
                    ),
                    StreamBuilder<bool>(
                      stream: playback.playingStream,
                      builder: (context, snapshot) {
                        final playing = snapshot.data ?? playback.isPlaying;
                        return IconButton(
                          onPressed: widget.controller.togglePlayPause,
                          icon: Icon(playing
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_filled),
                          iconSize: 64,
                          color: Tokens.accent,
                        );
                      },
                    ),
                    IconButton(
                      onPressed: widget.controller.next,
                      icon: const Icon(Icons.skip_next),
                      iconSize: 32,
                    ),
                  ],
                ),
                const SizedBox(height: Tokens.s16),
                Text(
                  'Queue ${queue.index + 1} of ${queue.tracks.length}',
                  style: text.bodySmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: Tokens.s4),
                Text(
                  'Pop back and return: the count and position are unchanged '
                  'because the queue lives above the navigator.',
                  style: text.labelSmall,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
