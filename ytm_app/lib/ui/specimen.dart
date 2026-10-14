import 'package:flutter/material.dart';

import '../theme/icons.dart';
import '../theme/tokens.dart';
import 'art_tile.dart';
import 'glass_surface.dart';
import 'pill_button.dart';
import 'seek_bar.dart';
import 'track_row.dart';

/// The design-system catalogue for the Phase 2 primitives.
///
/// This is a development screen, not a product screen: it renders the shared
/// primitives so they can be reviewed by hand and captured by the golden tests
/// before the adaptive shell (Phase 3) and the real screens (Phase 4) exist.
/// It carries no service data, only component specimens.
class SpecimenBoard extends StatelessWidget {
  const SpecimenBoard({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(Tokens.pageMarginPhone),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('Design system', style: Tokens.pageTitle),
          const SizedBox(height: Tokens.s4),
          const Text('Phase 2 primitives', style: Tokens.subtitle),
          const SizedBox(height: Tokens.s32),
          _section('Color', _swatches()),
          _section('Type', _typeScale()),
          _section('Glass', _glass()),
          _section('Buttons', _buttons()),
          _section('Artwork', _artwork()),
          _section('Rows', _rows()),
          _section('Seek bar', _seekBars(context)),
        ],
      ),
    );
  }

  Widget _section(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(title, style: Tokens.sectionHeader),
        const SizedBox(height: Tokens.s12),
        ...children,
        const SizedBox(height: Tokens.s32),
      ],
    );
  }

  List<Widget> _swatches() {
    const List<(String, Color)> entries = <(String, Color)>[
      ('bg', Tokens.bg),
      ('surface', Tokens.surface),
      ('surfaceRaised', Tokens.surfaceRaised),
      ('glass', Tokens.glass),
      ('glassStrong', Tokens.glassStrong),
      ('border', Tokens.border),
      ('borderStrong', Tokens.borderStrong),
      ('accent', Tokens.accent),
      ('text', Tokens.text),
      ('textSecondary', Tokens.textSecondary),
      ('textMuted', Tokens.textMuted),
      ('scrim', Tokens.scrim),
    ];

    return <Widget>[
      Wrap(
        spacing: Tokens.s16,
        runSpacing: Tokens.s12,
        children: entries
            .map(
              ((String, Color) e) => Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  DecoratedBox(
                    decoration: ShapeDecoration(
                      color: e.$2,
                      shape: Tokens.shapeFor(Tokens.rSmall),
                    ),
                    child: const SizedBox(
                      width: Tokens.s24,
                      height: Tokens.s24,
                    ),
                  ),
                  const SizedBox(width: Tokens.s8),
                  Text(e.$1, style: Tokens.caption),
                ],
              ),
            )
            .toList(),
      ),
    ];
  }

  List<Widget> _typeScale() {
    return const <Widget>[
      Text('Page title', style: Tokens.pageTitle),
      SizedBox(height: Tokens.s8),
      Text('Section header', style: Tokens.sectionHeader),
      SizedBox(height: Tokens.s8),
      Text('Row title', style: Tokens.rowTitle),
      SizedBox(height: Tokens.s8),
      Text('Subtitle', style: Tokens.subtitle),
      SizedBox(height: Tokens.s8),
      Text('Caption', style: Tokens.caption),
    ];
  }

  List<Widget> _glass() {
    return const <Widget>[
      GlassSurface(
        child: SizedBox(
          height: Tokens.miniPlayerHeight,
          child: Center(child: Text('glass', style: Tokens.rowTitle)),
        ),
      ),
      SizedBox(height: Tokens.s16),
      GlassSurface(
        isStrong: true,
        shape: Tokens.shapePill,
        child: SizedBox(
          height: Tokens.miniPlayerHeight,
          child: Center(child: Text('glassStrong pill', style: Tokens.rowTitle)),
        ),
      ),
    ];
  }

  List<Widget> _buttons() {
    return <Widget>[
      Wrap(
        spacing: Tokens.s12,
        runSpacing: Tokens.s12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          PillButton(
            icon: AppIcons.heart,
            onPressed: () {},
            label: 'Inactive',
          ),
          PillButton(
            icon: AppIcons.heartFill,
            onPressed: () {},
            isActive: true,
            label: 'Active',
          ),
          PillButton(
            icon: AppIcons.play,
            onPressed: () {},
          ),
        ],
      ),
    ];
  }

  List<Widget> _artwork() {
    return const <Widget>[
      Wrap(
        spacing: Tokens.s16,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          ArtTile(size: Tokens.artThumbSize, radius: Tokens.rSmall),
          ArtTile(size: Tokens.artTileSize, radius: Tokens.rCard),
          ArtTile(size: Tokens.heroArtDesktop, radius: Tokens.rLarge),
        ],
      ),
    ];
  }

  List<Widget> _rows() {
    return <Widget>[
      const TrackRow(
        title: 'Row title',
        subtitle: 'Subtitle',
        isPlaying: true,
        trailing: Icon(
          AppIcons.heartFill,
          size: Tokens.iconSize,
          color: Tokens.accent,
        ),
      ),
      const TrackRow(title: 'Row title', subtitle: 'Subtitle'),
      TrackRow(
        title: 'Row title',
        subtitle: 'Subtitle',
        onTap: () {},
        trailing: const Text('3:58', style: Tokens.caption),
      ),
    ];
  }

  List<Widget> _seekBars(BuildContext context) {
    return <Widget>[
      SeekBar(
        position: const Duration(seconds: 84),
        duration: const Duration(minutes: 3, seconds: 58),
        buffered: const Duration(minutes: 2, seconds: 30),
        onSeekStart: (_) {},
        onSeek: (_) {},
        onSeekEnd: (_) {},
      ),
      const SizedBox(height: Tokens.s24),
      const Text('Unknown duration, seeking disabled', style: Tokens.caption),
      const SizedBox(height: Tokens.s8),
      const SeekBar(
        position: Duration.zero,
        duration: Duration.zero,
        enabled: false,
      ),
    ];
  }
}
