import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/auth_controller.dart';
import 'auth_widgets.dart';
import 'bootstrap_screen.dart';
import 'change_password_screen.dart';
import 'lock_screen.dart';
import 'login_screen.dart';

/// Aiguillage du flux d'authentification pour tous les états NON authentifiés.
/// L'application principale (routeur) n'est jamais montée ici.
class AuthFlowScreen extends ConsumerWidget {
  const AuthFlowScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(authControllerProvider);
    return switch (state.status) {
      AuthStatus.loading => const _AuthLoadingScreen(),
      AuthStatus.bootstrapRequired => const BootstrapScreen(),
      AuthStatus.unauthenticated => const LoginScreen(),
      AuthStatus.passwordChangeRequired => const ChangePasswordScreen(),
      AuthStatus.locked => const LockScreen(),
      AuthStatus.error => _AuthErrorScreen(message: state.message),
      // Ne devrait pas arriver (l'app principale prend le relais) : neutre.
      AuthStatus.authenticated => const _AuthLoadingScreen(),
    };
  }
}

class _AuthLoadingScreen extends StatelessWidget {
  const _AuthLoadingScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: authBackground,
      body: Center(child: CircularProgressIndicator(color: authAccent)),
    );
  }
}

class _AuthErrorScreen extends ConsumerWidget {
  const _AuthErrorScreen({required this.message});

  final String? message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AuthScaffold(
      title: 'HomeSpotify',
      subtitle: 'Connexion au serveur impossible',
      children: [
        const Icon(Icons.cloud_off_rounded, color: Colors.white38, size: 40),
        const SizedBox(height: 12),
        AuthErrorText(message ?? 'Serveur HomeSpotify inaccessible.'),
        AuthSubmitButton(
          label: 'Réessayer',
          busy: false,
          onPressed: () => ref.read(authControllerProvider.notifier).retry(),
        ),
      ],
    );
  }
}
