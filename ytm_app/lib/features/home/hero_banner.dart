import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../data/ytm_repository.dart';
import '../../theme/icons.dart';
import '../../theme/tokens.dart';
import '../../ui/art_tile.dart';
import '../../ui/media_rows.dart';
import '../../ui/pill_button.dart';
import '../now_playing/artwork.dart';

/// The Home hero: the featured release, big.
///
/// Approved layout: large art, title, artist, and Play + Follow. Play opens the
/// release page, where the release's own Play queues and starts the album. It is
/// a flat [Tokens.surface] panel, not glass — glass is reserved for floating
/// chrome — but it is the one place artwork color is allowed in, as a soft tint
/// derived from the feature's own cover.
class HomeHeroBanner extends ConsumerWidget {
  const HomeHeroBanner({super.key, required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool isDesktop =
        MediaQuery.sizeOf(context).width >= Tokens.breakpointDesktop;
    final double artSize =
        isDesktop ? Tokens.heroArtDesktop : Tokens.collectionArtSize;
    final CollectionRef? target = item.collection;
    final OutlinedBorder shape = Tokens.shapeFor(Tokens.rLarge);

    return Padding(
      padding: const EdgeInsets.only(bottom: Tokens.s24),
      child: ClipPath(
        clipper: ShapeBorderClipper(
          shape: shape,
          textDirection: Directionality.maybeOf(context),
        ),
        child: DecoratedBox(
          decoration: ShapeDecoration(color: Tokens.surface, shape: shape),
          child: Stack(
            children: <Widget>[
              Positioned.fill(child: _HeroTint(url: item.artworkUrl)),
              Padding(
                padding: EdgeInsets.all(isDesktop ? Tokens.s24 : Tokens.s16),
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final Widget art = ArtTile(
                      size: artSize,
                      radius: Tokens.rCard,
                      image: ref.watch(artworkResolverProvider)(item.artworkUrl),
                    );
                    final Widget text = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          item.title,
                          style: Tokens.nowPlayingTitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (item.subtitle.isNotEmpty) ...<Widget>[
                          const SizedBox(height: Tokens.s4),
                          Text(
                            item.subtitle,
                            style: Tokens.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                        const SizedBox(height: Tokens.s16),
                        Wrap(
                          spacing: Tokens.s8,
                          runSpacing: Tokens.s8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: <Widget>[
                            PillButton(
                              icon: AppIcons.playFill,
                              label: 'Play',
                              isActive: true,
                              // Play opens the release; its page owns the
                              // queueing, so this never starts a second,
                              // parallel playback path.
                              onPressed: target == null
                                  ? null
                                  : () => openCollection(context, target),
                            ),
                            if (item.artistId != null)
                              _FollowButton(artistId: item.artistId!),
                          ],
                        ),
                      ],
                    );

                    // A narrow phone cannot fit the artwork and the actions
                    // side by side: the text column would be squeezed until
                    // the pills overflow. Below the threshold the hero
                    // stacks instead, which is the same content in a shape
                    // that fits.
                    if (constraints.maxWidth < Tokens.heroStackBelowWidth) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          art,
                          const SizedBox(height: Tokens.s16),
                          text,
                        ],
                      );
                    }

                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        art,
                        const SizedBox(width: Tokens.s16),
                        Expanded(child: text),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The real Follow action: it subscribes to the featured release's artist on the
/// account and reflects the state the sidecar reports back.
///
/// Optimistic, with a rollback. The label flips the moment the user taps,
/// because waiting on a round trip for a one-bit toggle feels broken; but a
/// failed write (offline, 401, 5xx) puts the label back to what the account is
/// actually in and says so in one short snackbar. Nothing is cached here: the
/// resting state is always re-read from the sidecar, so a restart shows the
/// subscription the account really has.
class _FollowButton extends ConsumerStatefulWidget {
  const _FollowButton({required this.artistId});

  final String artistId;

  @override
  ConsumerState<_FollowButton> createState() => _FollowButtonState();
}

class _FollowButtonState extends ConsumerState<_FollowButton> {
  /// The state the user just asked for, held only while the write is in flight
  /// (and while the confirming re-read lands). It is never persisted.
  bool? _optimistic;
  bool _pending = false;

  Future<void> _toggle(bool following) async {
    if (_pending) return;

    final bool target = !following;
    setState(() {
      _pending = true;
      _optimistic = target;
    });

    try {
      await ref
          .read(ytmRepositoryProvider)
          .setArtistSubscribed(widget.artistId, target);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _pending = false;
        // Roll back to the sidecar's answer: the account is not in the state
        // the button just showed.
        _optimistic = null;
      });
      _showFailure(error);
      return;
    }

    // The write landed. Re-read the subscription set rather than keeping the
    // guess, so the button settles on the account's own answer; the optimistic
    // value stays in place until that read arrives, which is what keeps the
    // label from flicking back to the old state mid-refresh.
    try {
      ref.invalidate(subscribedArtistsProvider);
      await ref.read(subscribedArtistsProvider.future);
    } catch (_) {
      // The account change succeeded; a failed re-read must not undo it.
    }
    if (!mounted) return;
    setState(() {
      _pending = false;
      _optimistic = null;
    });
  }

  void _showFailure(Object error) {
    final String message = error is YtmException
        ? error.message
        : 'Could not change the subscription.';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message, style: Tokens.subtitle),
          backgroundColor: Tokens.surfaceRaised,
          duration: Tokens.dSnackbar,
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final Set<String> subscribed =
        ref.watch(subscribedArtistsProvider).value ?? const <String>{};
    final bool fromSidecar =
        subscribed.contains(artistChannelKey(widget.artistId));
    final bool following = _optimistic ?? fromSidecar;

    return PillButton(
      icon: AppIcons.plus,
      label: following ? 'Following' : 'Follow',
      isActive: following,
      onPressed: _pending ? null : () => _toggle(following),
    );
  }
}

/// The banner's art-derived tint, cross-fading when the feature changes.
///
/// Color here comes only from the featured release's own cover (the palette
/// loader), faded into the flat surface so text stays legible. It renders
/// nothing while the palette is loading or unavailable.
class _HeroTint extends ConsumerStatefulWidget {
  const _HeroTint({required this.url});

  final String? url;

  @override
  ConsumerState<_HeroTint> createState() => _HeroTintState();
}

class _HeroTintState extends ConsumerState<_HeroTint> {
  List<Color> _colors = const <Color>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _HeroTint oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) _load();
  }

  Future<void> _load() async {
    final String? url = widget.url;
    if (url == null || url.isEmpty) {
      if (mounted) setState(() => _colors = const <Color>[]);
      return;
    }
    final List<Color> colors =
        await ref.read(ambientPaletteLoaderProvider)(url);
    if (!mounted || widget.url != url) return;
    setState(() => _colors = colors);
  }

  @override
  Widget build(BuildContext context) {
    if (_colors.isEmpty) return const SizedBox.shrink();

    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[
              _colors.first.withValues(alpha: Tokens.heroTintOpacity),
              Tokens.transparent,
            ],
          ),
        ),
      ),
    );
  }
}
