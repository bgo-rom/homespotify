import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/navigation.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shapes.dart';
import '../../../core/widgets/section_header.dart';
import '../../../core/widgets/soft_surface.dart';
import '../../auth/application/auth_controller.dart';

/// Écran « Profil » — refonte Direction 33. Onglet racine : le mini-player et
/// la navigation en pilule viennent de [HomeShell], pas d'ici.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final theme = Theme.of(context);
    final user = ref.watch(
      authControllerProvider.select((state) => state.user),
    );
    final name = user?.displayName.trim();
    final displayName = name == null || name.isEmpty ? 'Mon profil' : name;
    final initial = displayName.substring(0, 1).toUpperCase();

    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(
          key: const PageStorageKey<String>('profile-scroll'),
          slivers: [
            SliverToBoxAdapter(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: AppLayout.maxContentWidth,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppLayout.gutter,
                      16,
                      AppLayout.gutter,
                      32,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Profil',
                          style: theme.textTheme.displaySmall?.copyWith(
                            color: colors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 20),
                        _ProfileCard(
                          initial: initial,
                          displayName: displayName,
                          username: user?.username,
                          role: user?.role,
                        ),
                        const SizedBox(height: 28),
                        const SectionHeader(title: 'Mon espace'),
                        const SizedBox(height: 10),
                        _ProfileAction(
                          key: const ValueKey('profile-add-music-action'),
                          icon: Icons.add_circle_outline_rounded,
                          title: 'Ajouter une musique',
                          subtitle:
                              'Rechercher un titre et l’installer directement',
                          onTap: () => openCatalogSearch(context),
                        ),
                        _ProfileAction(
                          icon: Icons.manage_accounts_outlined,
                          title: 'Compte et paramètres',
                          subtitle: 'Sécurité, serveur et préférences',
                          onTap: () => openSettings(context),
                        ),
                        if (user?.isOwner ?? false) ...[
                          const SizedBox(height: 28),
                          const SectionHeader(title: 'Administration OWNER'),
                          const SizedBox(height: 10),
                          _ProfileAction(
                            icon: Icons.admin_panel_settings_outlined,
                            title: 'Tableau de bord',
                            subtitle: 'Utilisateurs et outils serveur',
                            onTap: () => context.push('/admin'),
                          ),
                          _ProfileAction(
                            icon: Icons.move_to_inbox_outlined,
                            title: 'Imports utilisateurs',
                            subtitle: 'Suivre les fichiers entrants',
                            onTap: () => context.push('/admin/imports'),
                          ),
                        ],
                      ],
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
}

/// Identité de l'utilisateur : avatar sculpté en accent, nom, @identifiant
/// et rôle. Première chose vue sur l'écran — hiérarchie visuelle assumée.
class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.initial,
    required this.displayName,
    this.username,
    this.role,
  });

  final String initial;
  final String displayName;
  final String? username;
  final String? role;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    return SoftCard(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          SoftCircle(
            size: 64,
            color: colors.accent,
            child: Text(
              initial,
              style: theme.textTheme.headlineSmall?.copyWith(
                color: colors.onAccent,
              ),
            ),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                if (username != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    '@$username${role == null ? '' : ' · $role'}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Raccourci sculpté : icône, titre, sous-titre, chevron. Une seule rangée
/// tactile — même grammaire que les tuiles de Bibliothèque.
class _ProfileAction extends StatelessWidget {
  const _ProfileAction({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: SoftCard(
        onTap: onTap,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            SoftCircle(
              size: 44,
              color: colors.accentSoft,
              child: Icon(icon, color: colors.accent, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: colors.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}
