import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/auth_controller.dart';
import 'auth_widgets.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    ref
        .read(authControllerProvider.notifier)
        .login(username: _username.text, password: _password.text);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(authControllerProvider);
    return AuthScaffold(
      title: 'HomeSpotify',
      subtitle: 'Connectez-vous à votre bibliothèque musicale.',
      children: [
        AuthTextField(
          controller: _username,
          label: 'Nom d’utilisateur',
          enabled: !state.busy,
          autofillHints: const [AutofillHints.username],
        ),
        AuthTextField(
          controller: _password,
          label: 'Mot de passe',
          obscure: true,
          enabled: !state.busy,
          autofillHints: const [AutofillHints.password],
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
        ),
        AuthErrorText(state.message),
        AuthSubmitButton(
          label: 'Se connecter',
          busy: state.busy,
          onPressed: _submit,
        ),
      ],
    );
  }
}
