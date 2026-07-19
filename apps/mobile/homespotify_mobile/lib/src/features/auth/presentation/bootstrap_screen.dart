import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/auth_controller.dart';
import 'auth_widgets.dart';

/// Création du premier compte : il devient l'unique OWNER de HomeSpotify.
class BootstrapScreen extends ConsumerStatefulWidget {
  const BootstrapScreen({super.key});

  @override
  ConsumerState<BootstrapScreen> createState() => _BootstrapScreenState();
}

class _BootstrapScreenState extends ConsumerState<BootstrapScreen> {
  final _username = TextEditingController();
  final _displayName = TextEditingController();
  final _password = TextEditingController();
  final _confirmation = TextEditingController();

  @override
  void dispose() {
    _username.dispose();
    _displayName.dispose();
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  void _submit() {
    ref
        .read(authControllerProvider.notifier)
        .bootstrap(
          username: _username.text,
          displayName: _displayName.text,
          password: _password.text,
          passwordConfirmation: _confirmation.text,
        );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(authControllerProvider);
    return AuthScaffold(
      title: 'Bienvenue dans HomeSpotify',
      subtitle:
          'Créez le compte propriétaire. Ce premier compte contrôle '
          'entièrement le serveur.',
      children: [
        AuthTextField(
          controller: _username,
          label: 'Nom d’utilisateur',
          enabled: !state.busy,
          autofillHints: const [AutofillHints.newUsername],
        ),
        AuthTextField(
          controller: _displayName,
          label: 'Nom affiché',
          enabled: !state.busy,
        ),
        AuthTextField(
          controller: _password,
          label: 'Mot de passe (10 caractères minimum)',
          obscure: true,
          enabled: !state.busy,
          autofillHints: const [AutofillHints.newPassword],
        ),
        AuthTextField(
          controller: _confirmation,
          label: 'Confirmation du mot de passe',
          obscure: true,
          enabled: !state.busy,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
        ),
        AuthErrorText(state.message),
        AuthSubmitButton(
          label: 'Créer le compte propriétaire',
          busy: state.busy,
          onPressed: _submit,
        ),
      ],
    );
  }
}
