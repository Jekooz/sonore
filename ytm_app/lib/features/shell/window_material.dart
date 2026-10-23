import 'dart:io';

import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;

import '../../theme/tokens.dart';

/// The native window material behind the in-app backdrop (Windows only).
///
/// The spec's reduce-transparency rule reaches all the way down to the window
/// itself: while Reduce transparency (or OS high contrast) is on, the Mica
/// material is swapped for a solid [Tokens.bg] fill, and back to Mica when the
/// preference is lifted. Every call is a no-op when `flutter_acrylic` cannot
/// serve the platform (Windows 10 often keeps the plain surface, which the
/// startup path already tolerates), so a failure here never fails the app.
class WindowMaterial {
  WindowMaterial._();

  /// Last requested state, so repeated calls during rebuilds are no-ops.
  static bool _lastSolid = false;

  /// Applies the material for [solid]. Safe on every platform: outside
  /// Windows it does nothing. Boot passes [force] to establish the initial
  /// state; later calls are deduplicated.
  static Future<void> apply({required bool solid, bool force = false}) async {
    if (!Platform.isWindows) return;
    if (!force && _lastSolid == solid) return;
    _lastSolid = solid;
    try {
      await acrylic.Window.setEffect(
        effect: solid ? acrylic.WindowEffect.solid : acrylic.WindowEffect.mica,
        dark: true,
        color: Tokens.bg,
      );
    } catch (_) {
      // The plain window surface stays — the startup path already renders
      // correctly on it.
    }
  }
}
