import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../application/auth_controller.dart';
import 'auth_widgets.dart';

/// Changement obligatoire du mot de passe (compte créé par le OWNER ou reset).
class ChangePasswordScreen extends ConsumerStatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  ConsumerState<ChangePasswordScreen> createState() =>
      _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends ConsumerState<ChangePasswordScreen> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirmation = TextEditingController();

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  void _submit() {
    ref
        .read(authControllerProvider.notifier)
        .changePassword(
          currentPassword: _current.text,
          newPassword: _next.text,
          newPasswordConfirmation: _confirmation.text,
        );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final state = ref.watch(authControllerProvider);
    return AuthScaffold(
      title: 'Nouveau mot de passe requis',
      subtitle:
          'Votre mot de passe est temporaire. Choisissez-en un nouveau pour '
          'continuer.',
      children: [
        AuthTextField(
          controller: _current,
          label: 'Mot de passe actuel',
          obscure: true,
          enabled: !state.busy,
        ),
        AuthTextField(
          controller: _next,
          label: 'Nouveau mot de passe (10 caractères minimum)',
          obscure: true,
          enabled: !state.busy,
          autofillHints: const [AutofillHints.newPassword],
        ),
        AuthTextField(
          controller: _confirmation,
          label: 'Confirmation du nouveau mot de passe',
          obscure: true,
          enabled: !state.busy,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
        ),
        AuthErrorText(state.message),
        AuthSubmitButton(
          label: 'Changer le mot de passe',
          busy: state.busy,
          onPressed: _submit,
        ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: state.busy
              ? null
              : () => ref.read(authControllerProvider.notifier).logout(),
          child: Text(
            'Se déconnecter',
            style: TextStyle(color: colors.textSecondary),
          ),
        ),
      ],
    );
  }
}
