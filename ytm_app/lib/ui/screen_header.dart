import 'package:flutter/material.dart';

import '../theme/icons.dart';
import '../theme/tokens.dart';

/// The header shared by the detail screens: a back action, the page title and
/// an optional trailing control.
///
/// The back action goes to Now Playing because that is where Lyrics, Equalizer
/// and Settings are opened from, and because it keeps the Now Playing bar and the
/// adaptive navigation exactly where the reader left them.
class ScreenHeader extends StatelessWidget {
  const ScreenHeader({
    super.key,
    required this.title,
    this.trailing,
    this.onBack,
    this.backLabel = 'Back to Now Playing',
    this.padding = const EdgeInsets.symmetric(
      horizontal: Tokens.pageMarginPhone,
      vertical: Tokens.s12,
    ),
  });

  final String title;
  final Widget? trailing;

  /// Where the back action goes. Defaults to Now Playing.
  final VoidCallback? onBack;

  final String backLabel;

  /// Set to zero when the header sits inside a page's content column, so the
  /// back arrow aligns to that column's left edge.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        children: <Widget>[
          Semantics(
            button: true,
            label: backLabel,
            child: IconButton(
              icon: const Icon(
                AppIcons.caretLeft,
                size: Tokens.iconSize,
                color: Tokens.text,
              ),
              tooltip: backLabel,
              onPressed: onBack ?? () => Navigator.of(context).maybePop(),
            ),
          ),
          const SizedBox(width: Tokens.s8),
          Expanded(
            child: Text(
              title,
              style: Tokens.pageTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
