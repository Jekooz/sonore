import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens a URL in the user's default browser.
///
/// A seam like [folderRevealerProvider]: widget tests must never launch a
/// browser, so the default is only installed by the composition root
/// (`main.dart`) and tests override the provider with a recorder. Returns
/// whether the OS accepted the request, which is what lets the sign-in flow
/// fall back to the sidecar opening the browser itself.
typedef BrowserOpener = Future<bool> Function(Uri uri);

/// The no-op default: sign-in still works (the sidecar opens the browser as a
/// fallback), and no widget test ever launches anything.
final Provider<BrowserOpener> browserOpenerProvider =
    Provider<BrowserOpener>((ref) => (Uri uri) async => false);

/// The real opener, installed in `main.dart`.
Future<bool> launchInBrowser(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.platformDefault);
