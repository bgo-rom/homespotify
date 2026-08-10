import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shapes.dart';
import '../../../core/widgets/soft_surface.dart';

/// Gabarit commun des écrans d'authentification — Direction 33. Fond de page,
/// badge sculpté, carte unique pour le formulaire ; même grammaire que le
/// reste de l'application (`SoftCard`, `SoftCircle`, `context.colors`).
class AuthScaffold extends StatelessWidget {
  const AuthScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    required this.children,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: SoftCircle(
                      size: 76,
                      color: colors.accent,
                      shadows: colors.clayShadow,
                      child: Icon(
                        Icons.music_note_rounded,
                        color: colors.onAccent,
                        size: 36,
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    subtitle,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.textSecondary,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 24),
                  SoftCard(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: children,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AuthTextField extends StatelessWidget {
  const AuthTextField({
    super.key,
    required this.controller,
    required this.label,
    this.obscure = false,
    this.enabled = true,
    this.autofillHints,
    this.textInputAction = TextInputAction.next,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final bool obscure;
  final bool enabled;
  final Iterable<String>? autofillHints;
  final TextInputAction textInputAction;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        controller: controller,
        enabled: enabled,
        obscureText: obscure,
        autofillHints: autofillHints,
        textInputAction: textInputAction,
        onSubmitted: onSubmitted,
        autocorrect: false,
        enableSuggestions: !obscure,
        style: TextStyle(color: colors.textPrimary),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(color: colors.textSecondary),
          filled: true,
          fillColor: colors.surfaceSunken,
          border: OutlineInputBorder(
            borderRadius: AppRadius.chipRadius,
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: AppRadius.chipRadius,
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: AppRadius.chipRadius,
            borderSide: BorderSide(color: colors.accent, width: 1.5),
          ),
          disabledBorder: OutlineInputBorder(
            borderRadius: AppRadius.chipRadius,
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}

class AuthErrorText extends StatelessWidget {
  const AuthErrorText(this.message, {super.key});

  final String? message;

  @override
  Widget build(BuildContext context) {
    if (message == null || message!.isEmpty) return const SizedBox.shrink();
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        message!,
        textAlign: TextAlign.center,
        style: TextStyle(color: colors.danger, fontSize: 13, height: 1.3),
      ),
    );
  }
}

class AuthSubmitButton extends StatelessWidget {
  const AuthSubmitButton({
    super.key,
    required this.label,
    required this.busy,
    required this.onPressed,
  });

  final String label;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: colors.accent,
        foregroundColor: colors.onAccent,
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: AppRadius.chipRadius),
      ),
      onPressed: busy ? null : onPressed,
      child: busy
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colors.onAccent,
              ),
            )
          : Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
    );
  }
}
