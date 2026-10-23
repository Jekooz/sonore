import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The shared content column every page lays its body into.
///
/// Browsing pages (Home, Search, Library, collection pages, Queue) center and
/// cap their content at [Tokens.contentMaxWidth] so line lengths stay readable
/// on ultrawide windows; form pages (Settings, Equalizer) use the narrower
/// [Tokens.formMaxWidth]. The horizontal gutter itself stays with each page's
/// own [Tokens.pageMargin] padding, which keeps the rail edges aligned with the
/// window's edges at phone widths.
class ContentColumn extends StatelessWidget {
  const ContentColumn({super.key, this.maxWidth, required this.child});

  /// Defaults to the browsing width ([Tokens.contentMaxWidth]); form pages
  /// (Settings, Equalizer) pass [Tokens.formMaxWidth] for their narrower
  /// control column.
  final double? maxWidth;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth ?? Tokens.contentMaxWidth,
        ),
        child: child,
      ),
    );
  }
}
