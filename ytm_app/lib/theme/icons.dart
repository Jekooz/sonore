import 'package:flutter/widgets.dart';

/// The one icon set: Phosphor, regular weight, with the filled variant marking
/// an active state (active tab, liked heart, playing track).
///
/// The spec bans `Icons.*` and any second icon set, so every widget imports
/// `AppIcons` instead of an icon package. The glyphs are drawn from the
/// Phosphor fonts bundled in `assets/fonts/`; the codepoints below are taken
/// from the canonical Phosphor release (Regular and Fill share a codepoint —
/// the style lives in the font family).
///
/// `phosphor_flutter` itself is deliberately not a dependency: its latest
/// release (2.1.0) declares `class PhosphorIconData extends IconData`, and
/// `IconData` is a `final class` in this Flutter version, so its Dart cannot
/// compile. The fonts are MIT-licensed (see
/// `assets/fonts/Phosphor-LICENSE.txt`).
class AppIcons {
  AppIcons._();

  static const String _regular = 'PhosphorRegular';
  static const String _fill = 'PhosphorFill';

  // ------------------------------------------------------------ Navigation ---

  static const IconData house =
      IconData(0xe2c2, fontFamily: _regular, matchTextDirection: true);
  static const IconData houseFill =
      IconData(0xe2c2, fontFamily: _fill, matchTextDirection: true);

  static const IconData magnifyingGlass =
      IconData(0xe30c, fontFamily: _regular, matchTextDirection: true);
  static const IconData magnifyingGlassFill =
      IconData(0xe30c, fontFamily: _fill, matchTextDirection: true);

  static const IconData listBullets =
      IconData(0xe2f2, fontFamily: _regular, matchTextDirection: true);
  static const IconData listBulletsFill =
      IconData(0xe2f2, fontFamily: _fill, matchTextDirection: true);

  static const IconData musicNotes =
      IconData(0xe340, fontFamily: _regular, matchTextDirection: true);
  static const IconData musicNotesFill =
      IconData(0xe340, fontFamily: _fill, matchTextDirection: true);

  // -------------------------------------------------------------- Playback ---

  static const IconData play =
      IconData(0xe3d0, fontFamily: _regular, matchTextDirection: true);
  static const IconData playFill =
      IconData(0xe3d0, fontFamily: _fill, matchTextDirection: true);

  static const IconData pause =
      IconData(0xe39e, fontFamily: _regular, matchTextDirection: true);
  static const IconData pauseFill =
      IconData(0xe39e, fontFamily: _fill, matchTextDirection: true);

  static const IconData skipBack =
      IconData(0xe5a4, fontFamily: _regular, matchTextDirection: true);

  static const IconData skipForward =
      IconData(0xe5a6, fontFamily: _regular, matchTextDirection: true);

  static const IconData shuffle =
      IconData(0xe422, fontFamily: _regular, matchTextDirection: true);

  static const IconData repeat =
      IconData(0xe3f6, fontFamily: _regular, matchTextDirection: true);

  static const IconData queue =
      IconData(0xe6ac, fontFamily: _regular, matchTextDirection: true);

  // --------------------------------------------------------------- Actions ---

  static const IconData heart =
      IconData(0xe2a8, fontFamily: _regular, matchTextDirection: true);
  static const IconData heartFill =
      IconData(0xe2a8, fontFamily: _fill, matchTextDirection: true);

  static const IconData textAa =
      IconData(0xe6ee, fontFamily: _regular, matchTextDirection: true);

  static const IconData faders =
      IconData(0xe228, fontFamily: _regular, matchTextDirection: true);

  static const IconData speakerHigh =
      IconData(0xe44a, fontFamily: _regular, matchTextDirection: true);

  static const IconData dotsThree =
      IconData(0xe1fe, fontFamily: _regular, matchTextDirection: true);

  static const IconData image =
      IconData(0xe2ca, fontFamily: _regular, matchTextDirection: true);

  static const IconData caretLeft =
      IconData(0xe138, fontFamily: _regular, matchTextDirection: true);

  static const IconData caretRight =
      IconData(0xe13a, fontFamily: _regular, matchTextDirection: true);

  static const IconData caretUp =
      IconData(0xe13c, fontFamily: _regular, matchTextDirection: true);

  /// Verified against the bundled font rather than trusted: the glyph at
  /// 0xe136 renders (it is not tofu) as a chevron whose arms converge towards
  /// the bottom, and it sits immediately before `caretLeft`/`caretRight` in the
  /// codepoint order the two known carets already follow.
  static const IconData caretDown =
      IconData(0xe136, fontFamily: _regular, matchTextDirection: true);

  static const IconData dotsThreeVertical =
      IconData(0xe208, fontFamily: _regular, matchTextDirection: true);

  static const IconData arrowClockwise =
      IconData(0xe036, fontFamily: _regular, matchTextDirection: true);

  static const IconData wifiSlash =
      IconData(0xe4f2, fontFamily: _regular, matchTextDirection: true);

  /// Adds to a queue (context menu, collection headers).
  static const IconData plus =
      IconData(0xe3d4, fontFamily: _regular, matchTextDirection: true);

  /// Copies a share link (context menu).
  static const IconData linkSimple =
      IconData(0xe2e6, fontFamily: _regular, matchTextDirection: true);

  /// Opens an album (context menu).
  static const IconData disc =
      IconData(0xe564, fontFamily: _regular, matchTextDirection: true);

  /// Opens an artist (context menu).
  static const IconData user =
      IconData(0xe4c2, fontFamily: _regular, matchTextDirection: true);

  /// Signs out (Settings → Account). Phosphor's `sign-out`: the codepoint comes
  /// from the same canonical release as every other glyph here
  /// (`@phosphor-icons/web` 2.1.1, where the codepoints of the icons already in
  /// this file match theirs exactly) and it was checked against the bundled
  /// font's own character map, so it renders the door-and-arrow glyph rather
  /// than tofu.
  static const IconData signOut =
      IconData(0xe42a, fontFamily: _regular, matchTextDirection: true);

  /// Library sort control.
  static const IconData sortAscending =
      IconData(0xe444, fontFamily: _regular, matchTextDirection: true);

  /// A previous search, i.e. history rather than a refresh.
  static const IconData clockCounterClockwise =
      IconData(0xe1a0, fontFamily: _regular, matchTextDirection: true);

  // ----------------------------------------------- Windows caption buttons ---

  static const IconData minimize =
      IconData(0xe32a, fontFamily: _regular, matchTextDirection: true);

  static const IconData maximize =
      IconData(0xe1d0, fontFamily: _regular, matchTextDirection: true);

  static const IconData restore =
      IconData(0xe1ce, fontFamily: _regular, matchTextDirection: true);

  static const IconData close =
      IconData(0xe4f6, fontFamily: _regular, matchTextDirection: true);
}
