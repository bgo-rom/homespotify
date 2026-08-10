import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../application/auth_controller.dart';
import 'auth_widgets.dart';

/// Verrou local : la session existe mais exige la biométrie pour s'ouvrir.
/// Le retour au mot de passe abandonne la session locale (déconnexion propre).
class LockScreen extends ConsumerWidget {
  const LockScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final state = ref.watch(authControllerProvider);
    final controller = ref.read(authControllerProvider.notifier);
    return AuthScaffold(
      title: 'HomeSpotify verrouillé',
      subtitle: 'Déverrouillez avec votre empreinte ou votre visage.',
      children: [
        Icon(Icons.fingerprint_rounded, color: colors.accent, size: 64),
        const SizedBox(height: 16),
        AuthSubmitButton(
          label: 'Déverrouiller',
          busy: state.busy,
          onPressed: controller.unlockWithBiometrics,
        ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: state.busy ? null : controller.usePasswordInstead,
          child: Text(
            'Se reconnecter avec le mot de passe',
            style: TextStyle(color: colors.textSecondary),
          ),
        ),
      ],
    );
  }
}
