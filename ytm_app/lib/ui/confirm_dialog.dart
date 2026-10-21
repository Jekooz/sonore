import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'glass_surface.dart';

/// Confirm-forwarding helper for the destructive confirmations.
///
/// A dialog is one of the glass surfaces the spec lists, so it is built from
/// [GlassSurface] (thick tier, the largest radius) instead of a flat
/// AlertDialog background: the confirmation floats over whatever paused behind
/// it and blends with the backdrop while it does.
///
/// Only confirmations use this — an ask/confirm two-liner, not forms. The
/// buttons stay standard Material controls, so keyboard behavior, focus order
/// and screen-reader semantics keep their defaults.
Future<bool?> confirmDialog(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
}) {
  return showDialog<bool>(
    context: context,
    builder: (BuildContext context) => Dialog(
      backgroundColor: Tokens.transparent,
      child: GlassSurface(
        tier: GlassTier.thick,
        radius: Tokens.rLarge,
        child: Padding(
          // The pane's own padding keeps title, body and actions inside the
          // glass instead of hugging its edges.
          padding: const EdgeInsets.all(Tokens.s24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title, style: Tokens.sectionHeader),
              const SizedBox(height: Tokens.s12),
              Text(body, style: Tokens.subtitle),
              const SizedBox(height: Tokens.s24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text(cancelLabel, style: Tokens.subtitle),
                  ),
                  const SizedBox(width: Tokens.s8),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: Text(
                      confirmLabel,
                      style: Tokens.subtitle.copyWith(
                        color: Tokens.text,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
