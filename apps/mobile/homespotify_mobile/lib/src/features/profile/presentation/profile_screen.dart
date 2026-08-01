import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/navigation.dart';
import '../../../core/theme/home_design.dart';
import '../../auth/application/auth_controller.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(
      authControllerProvider.select((state) => state.user),
    );
    final name = user?.displayName.trim();
    final displayName = name == null || name.isEmpty ? 'Mon profil' : name;
    final initial = displayName.substring(0, 1).toUpperCase();

    return Scaffold(
      backgroundColor: HomeDesign.background,
      body: SafeArea(
        child: CustomScrollView(
          key: const PageStorageKey<String>('profile-scroll'),
          slivers: [
            SliverToBoxAdapter(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: HomeDesign.maxContentWidth,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Profil',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 30,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: HomeDesign.space20),
                        _ProfileCard(
                          initial: initial,
                          displayName: displayName,
                          username: user?.username,
                          role: user?.role,
                        ),
                        const SizedBox(height: HomeDesign.space24),
                        const _SectionTitle('Mon espace'),
                        const SizedBox(height: HomeDesign.space8),
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
                          const SizedBox(height: HomeDesign.space24),
                          const _SectionTitle('Administration OWNER'),
                          const SizedBox(height: HomeDesign.space8),
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
    return Material(
      color: HomeDesign.surface,
      borderRadius: BorderRadius.circular(HomeDesign.radiusLarge),
      child: Padding(
        padding: const EdgeInsets.all(HomeDesign.space20),
        child: Row(
          children: [
            CircleAvatar(
              radius: 30,
              backgroundColor: HomeDesign.accent,
              foregroundColor: Colors.black,
              child: Text(
                initial,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: HomeDesign.space16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    displayName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (username != null)
                    Text(
                      '@$username${role == null ? '' : ' · $role'}',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 13,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Text(
    title,
    style: const TextStyle(
      color: Colors.white70,
      fontSize: 13,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.5,
    ),
  );
}

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
    return Padding(
      padding: const EdgeInsets.only(bottom: HomeDesign.space8),
      child: Material(
        color: HomeDesign.surface,
        borderRadius: BorderRadius.circular(HomeDesign.radiusMedium),
        child: ListTile(
          minTileHeight: 68,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(HomeDesign.radiusMedium),
          ),
          leading: Icon(icon, color: HomeDesign.accent),
          title: Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white54),
          ),
          trailing: const Icon(
            Icons.chevron_right_rounded,
            color: Colors.white38,
          ),
          onTap: onTap,
        ),
      ),
    );
  }
}
