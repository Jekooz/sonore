import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Opens a folder in the operating system's file manager.
///
/// A seam rather than a direct call, so no widget test or golden ever opens a
/// window: the default does nothing at all, and the composition root
/// (`main.dart`) installs the real one. This is the same shape as the app's
/// other platform effects, such as the sidecar launcher.
typedef FolderRevealer = Future<void> Function(String path);

/// The no-op default. Sign-in screens still render their instructions with it,
/// which is exactly what a widget test wants to observe.
final Provider<FolderRevealer> folderRevealerProvider =
    Provider<FolderRevealer>((ref) => (String path) async {});
