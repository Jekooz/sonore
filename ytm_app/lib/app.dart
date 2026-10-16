import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/app_identity.dart';
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
    final AppSettings settings = ref.watch(appSettingsProvider);
    final double maxScale = settings.textScale;

    return MaterialApp.router(
      title: appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      themeMode: ThemeMode.dark,
      routerConfig: router,
      builder: (BuildContext context, Widget? child) {
        // The Reduce motion preference overrides the platform flag, so one
        // switch turns every animated transition in the app into a plain
        // cross-fade. It is folded into MediaQuery rather than read screen by
        // screen because every animated widget already asks MediaQuery.
        final MediaQueryData media = MediaQuery.of(context);
        return SidecarStartupGate(
          child: MediaQuery(
            data: media.copyWith(
              disableAnimations: media.disableAnimations || settings.reduceMotion,
            ),
            child: MediaQuery.withClampedTextScaling(
              minScaleFactor: Tokens.textScaleMin,
              maxScaleFactor: maxScale,
              child: child!,
            ),
          ),
        );
      },
    );
  }
}
