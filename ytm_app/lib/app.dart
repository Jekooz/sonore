import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/app_settings.dart';
import 'core/sidecar/sidecar_startup_gate.dart';
import 'theme/app_theme.dart';
import 'theme/tokens.dart';

/// The application root.
///
/// Dark-only: the spec's v1 has no light theme, and the existing theme system
/// builds a single token-based dark scheme, so there is nothing to switch.
/// Text scaling is clamped to the spec's ceiling, adjusted by the user's
/// preference, for every screen.
class YtmApp extends ConsumerWidget {
  const YtmApp({super.key, required this.router});

  final GoRouter router;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final double maxScale = ref.watch(
      appSettingsProvider.select((AppSettings settings) => settings.textScale),
    );

    return MaterialApp.router(
      title: 'YT Music Client',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      themeMode: ThemeMode.dark,
      routerConfig: router,
      builder: (BuildContext context, Widget? child) {
        return SidecarStartupGate(
          child: MediaQuery.withClampedTextScaling(
            minScaleFactor: Tokens.textScaleMin,
            maxScaleFactor: maxScale,
            child: child!,
          ),
        );
      },
    );
  }
}
