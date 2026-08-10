import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/clay_header.dart';
import '../../auth/application/auth_controller.dart';

/// Garde d'affichage des écrans d'administration : réservés au OWNER.
/// Le backend revérifie chaque appel — masquer l'UI ne suffit jamais.
class AdminGuard extends ConsumerWidget {
  const AdminGuard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(
      authControllerProvider.select((state) => state.user),
    );
    if (user == null || !user.isOwner) {
      final colors = context.colors;
      return Scaffold(
        backgroundColor: colors.background,
        body: SafeArea(
          child: Column(
            children: [
              ClayHeader(
                title: 'Administration',
                onBack: () => Navigator.of(context).maybePop(),
              ),
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Accès réservé au propriétaire de HomeSpotify.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return child;
  }
}

/// Formatage octets → libellé lisible (Go/Mo).
String formatBytes(int? bytes) {
  if (bytes == null) return '—';
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} Go';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} Mo';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} Ko';
  return '$bytes o';
}

String formatUptime(int seconds) {
  final days = seconds ~/ 86400;
  final hours = (seconds % 86400) ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  if (days > 0) return '$days j $hours h';
  if (hours > 0) return '$hours h $minutes min';
  return '$minutes min';
}

String formatDateTime(String? iso) {
  if (iso == null || iso.isEmpty) return 'Jamais';
  final date = DateTime.tryParse(iso)?.toLocal();
  if (date == null) return 'Jamais';
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(date.day)}/${two(date.month)}/${date.year} '
      '${two(date.hour)}:${two(date.minute)}';
}
