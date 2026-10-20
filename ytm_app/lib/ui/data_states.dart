import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api_client.dart';
import '../data/ytm_repository.dart';
import '../theme/icons.dart';
import '../theme/tokens.dart';
import 'screen_states.dart';

/// Shows the right state for the current connection before any data is fetched,
/// so Home, Search and Library agree on what "offline" and "not signed in" mean.
class ConnectionGate extends ConsumerWidget {
  const ConnectionGate({super.key, required this.child, this.loading});

  final Widget child;

  /// Replaces the default skeleton while the sidecar is being probed.
  final Widget? loading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<YtmConnection> connection = ref.watch(connectionProvider);

    if (connection.isLoading && !connection.hasValue) {
      return loading ?? const ListSkeleton();
    }

    final YtmConnection? value = connection.value;
    if (value == null) {
      // No value and not loading means the probe failed outright.
      return const OfflineState();
    }

    return switch (value.status) {
      YtmStatus.offline => const OfflineState(),
      YtmStatus.signedOut => const SignedOutState(),
      YtmStatus.ready => child,
    };
  }
}

/// The sidecar is not running. This is deliberately specific: the app talks to a
/// local service, and it holds no cache, so there is nothing to fall back on and
/// the state says so instead of implying the network is down.
class OfflineState extends ConsumerWidget {
  const OfflineState({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return StateMessage(
      message: 'YouTube Music is not reachable.',
      footnote:
          'The local music service is not running. '
          'Nothing is stored on this device to play instead.',
      actionLabel: 'Try again',
      actionIcon: AppIcons.arrowClockwise,
      onAction: () => ref.invalidate(connectionProvider),
    );
  }
}

/// The sidecar is running but has no session. The one real action starts a
/// sign-in the sidecar owns end to end: it either reads an already signed-in
/// Firefox profile straight from disk — no window, no click — or opens
/// Edge/Chrome in a profile it owns at music.youtube.com and reads the session
/// the moment the user has signed in.
///
/// Nothing is installed and no extension is involved, which is the point: the
/// old helper extension was a step only a technical user would take, and
/// leaving it out is what makes sign-in work for everyone else.
class SignedOutState extends ConsumerWidget {
  const SignedOutState({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SignInState signIn = ref.watch(signInProvider);
    final SignInController controller = ref.read(signInProvider.notifier);

    return switch (signIn.stage) {
      SignInStage.waiting => StateMessage(
        message: 'Waiting for you to sign in…',
        footnote: 'Sign in to YouTube Music with Google in '
            '${_signInWindow(signIn.browser)}. Close that window when you are '
            'done — or press I\'ve signed in and this closes it for you.',
        actionLabel: 'I\'ve signed in',
        onAction: controller.finish,
        secondaryLabel: 'Cancel',
        onSecondary: controller.cancel,
      ),
      SignInStage.done => const StateMessage(
        message: 'Signed in. Loading your music…',
      ),
      SignInStage.failed => StateMessage(
        message: signIn.detail ?? 'Sign-in did not complete.',
        footnote: 'You can start it again when you are ready.',
        actionLabel: 'Try again',
        actionIcon: AppIcons.arrowClockwise,
        onAction: controller.start,
      ),
      SignInStage.idle => StateMessage(
        message: 'Not signed in to YouTube Music.',
        footnote: 'Sign in with Google in the browser window that opens. Your '
            'session is kept by the local service — the app itself never stores '
            'it, and there is nothing to install.',
        actionLabel: 'Sign in',
        actionIcon: AppIcons.user,
        onAction: controller.start,
      ),
    };
  }
}

/// The window to name in the waiting copy: the browser the sidecar said it is
/// using, or a plain "browser window" when it has no opinion.
///
/// Worth naming, because sign-in opens a browser that is not the one the user
/// is looking at — a separate window for this app rather than their everyday
/// session — and "the browser window" leaves them wondering which.
String _signInWindow(String? browser) {
  if (browser == null || browser.isEmpty || browser == 'your browser') {
    return 'the browser window that just opened';
  }
  return 'the $browser window that just opened';
}

/// Renders loading / empty / error / populated for a data-backed screen.
///
/// The three failure kinds are shown differently on purpose: offline and
/// signed-out are states the user can act on, while a request failure keeps the
/// service's own words and offers a retry.
class DataStateView<T> extends ConsumerStatefulWidget {
  const DataStateView({
    super.key,
    required this.value,
    required this.data,
    required this.onRetry,
    this.loading,
    this.isEmpty,
    this.emptyMessage = 'Nothing here yet.',
    this.emptyFootnote,
  });

  final AsyncValue<T> value;
  final Widget Function(T data) data;
  final VoidCallback onRetry;
  final Widget? loading;
  final bool Function(T data)? isEmpty;
  final String emptyMessage;
  final String? emptyFootnote;

  @override
  ConsumerState<DataStateView<T>> createState() =>
      _DataStateViewState<T>();
}

class _DataStateViewState<T> extends ConsumerState<DataStateView<T>> {
  /// The error instance whose session-expiry refresh already ran.
  ///
  /// One-shot on purpose: invalidating the connection rebuilds the gate,
  /// which rebuilds this view, and doing that for every rebuild of the same
  /// error would spin forever. A new error object means a new 401.
  Object? _refreshedFor;

  /// A 401/422 means the sidecar dropped the stored session, so the cached
  /// connection — and with it "Signed in as" — is stale and the whole app
  /// should flip to the sign-in prompt instead of showing empty lists. The
  /// invalidation is deferred past the build phase because a provider may not
  /// be modified while the tree is building.
  void _refreshExpiredSession(Object? error) {
    if (error is! YtmSignedOutException || identical(error, _refreshedFor)) {
      return;
    }
    _refreshedFor = error;
    Future<void>.microtask(() {
      if (mounted) ref.invalidate(connectionProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<T> value = widget.value;

    if (value.isLoading && !value.hasValue) {
      return widget.loading ?? const ListSkeleton();
    }

    if (value.hasError) {
      _refreshExpiredSession(value.error);
      return dataErrorState(context, value.error!, widget.onRetry);
    }

    // `hasValue` — not `value == null` — is what distinguishes "the provider
    // never produced a value" from "the provider answered null". For a
    // nullable T (LyricsResult?), null IS the answer, and `isEmpty` decides
    // what to show for it.
    if (!value.hasValue) {
      _refreshExpiredSession(value.error);
      return dataErrorState(
        context,
        value.error ?? 'Unknown failure',
        widget.onRetry,
      );
    }

    final T current = value.value as T;
    if (widget.isEmpty?.call(current) ?? false) {
      return StateMessage(
        message: widget.emptyMessage,
        footnote: widget.emptyFootnote,
      );
    }

    return widget.data(current);
  }
}

/// Maps a repository failure onto the state the user should see.
Widget dataErrorState(
  BuildContext context,
  Object error,
  VoidCallback onRetry,
) {
  if (error is YtmOfflineException) return const OfflineState();
  if (error is YtmSignedOutException) return const SignedOutState();

  final String message = error is YtmException
      ? error.message
      : 'Something went wrong loading this.';

  return StateMessage(
    message: message,
    actionLabel: 'Try again',
    actionIcon: AppIcons.arrowClockwise,
    onAction: onRetry,
  );
}

/// Shimmering placeholder rows, shaped like the lists they stand in for.
class ListSkeleton extends StatelessWidget {
  const ListSkeleton({super.key, this.rows = 6, this.padding});

  final int rows;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: padding ?? const EdgeInsets.all(Tokens.s16),
      itemCount: rows,
      itemBuilder: (BuildContext context, int index) => const Padding(
        padding: EdgeInsets.symmetric(vertical: Tokens.s8),
        child: Row(
          children: <Widget>[
            Skeleton(
              width: Tokens.artThumbSize,
              height: Tokens.artThumbSize,
              radius: Tokens.rSmall,
            ),
            SizedBox(width: Tokens.s12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Skeleton(width: Tokens.artTileSize * 2),
                  SizedBox(height: Tokens.s8),
                  Skeleton(width: Tokens.artTileSize),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shimmering placeholder for a rail of artwork cards.
class RailSkeleton extends StatelessWidget {
  const RailSkeleton({super.key, this.count = 4});

  final int count;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: Tokens.railCardHeight,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: count,
        itemBuilder: (BuildContext context, int index) => const Padding(
          padding: EdgeInsets.only(right: Tokens.s16),
          child: Skeleton(
            width: Tokens.artTileSize,
            height: Tokens.railCardHeight,
            radius: Tokens.rCard,
          ),
        ),
      ),
    );
  }
}
