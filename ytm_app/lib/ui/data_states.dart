import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/folder_reveal.dart';
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

/// The sidecar is running but has no session. The one real action is the
/// project's established sign-in hand-off: the sidecar opens music.youtube.com
/// and waits for the companion extension.
///
/// The extension is not optional on this build. A browser only lets an extension
/// read a pairing file inside its own installation, so a copy loaded from
/// anywhere else can never hand the session over — and signing in to YouTube
/// Music in the browser on its own changes nothing. Once it is loaded (a
/// one-time step), the hand-off is automatic: the extension hands the session
/// over the moment the browser has one, with no token to copy and nothing to
/// press. The screen still names the folder and offers to open it, because
/// without the extension the wait ends in a three-minute timeout that reads as
/// a sign-in screen that does not work.
class SignedOutState extends ConsumerWidget {
  const SignedOutState({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SignInState signIn = ref.watch(signInProvider);
    final SignInController controller = ref.read(signInProvider.notifier);
    // Empty when the sidecar cannot answer, in which case the screen keeps its
    // generic wording instead of printing a blank path.
    final String folder = ref.watch(extensionFolderProvider).value ?? '';
    final bool hasFolder = folder.isNotEmpty;
    final VoidCallback? openFolder = hasFolder
        ? () => ref.read(folderRevealerProvider)(folder)
        : null;

    return switch (signIn.stage) {
      SignInStage.waiting => StateMessage(
        message: 'Waiting for you to sign in…',
        footnote: hasFolder
            ? 'In the browser window that just opened, sign in to YouTube Music '
                  'with Google. This finishes on its own — nothing else to press. '
                  'The Sonore Helper extension that completes it loads from:\n$folder'
            : 'Sign in to YouTube Music with Google in the browser window. This '
                  'finishes on its own — nothing else to press.',
        actionLabel: 'Cancel',
        actionIcon: AppIcons.close,
        onAction: controller.cancel,
        secondaryLabel: hasFolder ? 'Open extension folder' : null,
        onSecondary: openFolder,
      ),
      SignInStage.done => const StateMessage(
        message: 'Signed in. Loading your music…',
      ),
      SignInStage.failed => StateMessage(
        message: signIn.detail ?? 'Sign-in did not complete.',
        footnote: hasFolder
            ? 'You can start it again when you are ready. Sign-in finishes through '
                  'the helper extension, which loads from:\n$folder'
            : 'You can start it again when you are ready.',
        actionLabel: 'Try again',
        actionIcon: AppIcons.arrowClockwise,
        onAction: controller.start,
        secondaryLabel: hasFolder ? 'Open extension folder' : null,
        onSecondary: openFolder,
      ),
      SignInStage.idle => StateMessage(
        message: 'Not signed in to YouTube Music.',
        footnote: hasFolder
            ? 'Sign in with Google in your browser — the Sonore Helper extension '
                  'hands the session to the app automatically, so there is no '
                  'token to copy. Load it once from:\n$folder\nthen turn on '
                  'Developer mode and choose "Load unpacked".'
            : 'Sign-in opens in your browser and finishes on its own, and your '
                  'session is kept by the local service — the app never stores it.',
        actionLabel: 'Sign in',
        actionIcon: AppIcons.user,
        onAction: controller.start,
        secondaryLabel: hasFolder ? 'Open extension folder' : null,
        onSecondary: openFolder,
      ),
    };
  }
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
