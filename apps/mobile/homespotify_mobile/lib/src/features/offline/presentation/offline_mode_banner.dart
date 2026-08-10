import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../auth/application/auth_controller.dart';

/// Enveloppe l'application principale et affiche un bandeau discret quand la
/// session tourne en « Mode hors connexion » (serveur injoignable, session
/// locale connue). Aucun bandeau en fonctionnement normal.
class OfflineAwareShell extends ConsumerWidget {
  const OfflineAwareShell({super.key, required this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offline = ref.watch(
      authControllerProvider.select(
        (state) => state.status == AuthStatus.offline,
      ),
    );
    final content = child ?? const SizedBox.shrink();
    if (!offline) return content;
    return Column(
      children: [
        const OfflineModeBanner(),
        Expanded(child: content),
      ],
    );
  }
}

class OfflineModeBanner extends ConsumerWidget {
  const OfflineModeBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    return Material(
      color: colors.surfaceRaised,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Row(
            children: [
              Icon(
                Icons.cloud_off_rounded,
                size: 16,
                color: colors.textSecondary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Mode hors connexion — musiques téléchargées uniquement',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 12.5,
                  ),
                ),
              ),
              TextButton(
                key: const ValueKey('offline-banner-retry'),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 30),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                onPressed: () => ref
                    .read(authControllerProvider.notifier)
                    .attemptOnlineRestore(),
                child: Text(
                  'Réessayer',
                  style: TextStyle(color: colors.accent, fontSize: 12.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
