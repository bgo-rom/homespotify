import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shapes.dart';
import '../../../core/widgets/clay_header.dart';
import '../../../core/widgets/soft_surface.dart';
import '../data/admin_api.dart';
import 'admin_guard.dart';

/// Gestion des comptes par le OWNER. Chaque action destructive passe par une
/// confirmation explicite ; le backend revérifie systématiquement les droits.
class AdminUsersScreen extends ConsumerStatefulWidget {
  const AdminUsersScreen({super.key});

  @override
  ConsumerState<AdminUsersScreen> createState() => _AdminUsersScreenState();
}

class _AdminUsersScreenState extends ConsumerState<AdminUsersScreen> {
  List<AdminUser>? _users;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    logUi('ouverture Administration/Utilisateurs');
    _refresh();
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final users = await ref.read(adminApiProvider).listUsers();
      if (!mounted) return;
      setState(() {
        _users = users;
        _loading = false;
      });
    } on AdminApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    }
  }

  Future<void> _runAction(Future<void> Function() action) async {
    final colors = context.colors;
    try {
      await action();
      await _refresh();
    } on AdminApiException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(backgroundColor: colors.surfaceRaised, content: Text(error.message)),
      );
    }
  }

  Future<bool> _confirm(String title, String message) async {
    final colors = context.colors;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: colors.surface,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.cardRadius),
        title: Text(title, style: TextStyle(color: colors.textPrimary)),
        content: Text(message, style: TextStyle(color: colors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(
              'Annuler',
              style: TextStyle(color: colors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text('Confirmer', style: TextStyle(color: colors.danger)),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _onAction(AdminUser user, _UserAction action) async {
    final api = ref.read(adminApiProvider);
    switch (action) {
      case _UserAction.block:
        if (await _confirm(
          'Bloquer ${user.displayName} ?',
          'Le compte ne pourra plus se connecter et toutes ses sessions '
              'seront révoquées.',
        )) {
          await _runAction(
            () => api.setUserStatus(userId: user.id, isActive: false),
          );
        }
      case _UserAction.unblock:
        if (await _confirm(
          'Réactiver ${user.displayName} ?',
          'Le compte pourra de nouveau se connecter.',
        )) {
          await _runAction(
            () => api.setUserStatus(userId: user.id, isActive: true),
          );
        }
      case _UserAction.revokeSessions:
        if (await _confirm(
          'Révoquer les sessions de ${user.displayName} ?',
          'Tous ses appareils devront se reconnecter.',
        )) {
          await _runAction(() => api.revokeSessions(userId: user.id));
        }
      case _UserAction.resetPassword:
        final password = await _TemporaryPasswordDialog.show(context);
        if (password != null) {
          await _runAction(
            () =>
                api.resetPassword(userId: user.id, temporaryPassword: password),
          );
        }
      case _UserAction.toggleRole:
        final newRole = user.role == 'ADMIN' ? 'USER' : 'ADMIN';
        if (await _confirm(
          'Passer ${user.displayName} en $newRole ?',
          newRole == 'ADMIN'
              ? 'Le compte recevra les droits ADMIN (limités à ce que le '
                    'backend autorise explicitement).'
              : 'Le compte redeviendra un utilisateur standard.',
        )) {
          await _runAction(
            () => api.setUserRole(userId: user.id, role: newRole),
          );
        }
      case _UserAction.delete:
        if (await _confirm(
          'Supprimer ${user.displayName} ?',
          'Suppression définitive du compte et de ses sessions. Les fichiers '
              'audio de la bibliothèque ne sont pas supprimés.',
        )) {
          await _runAction(() => api.deleteUser(userId: user.id));
        }
    }
  }

  Future<void> _createUser() async {
    final input = await _CreateUserDialog.show(context);
    if (input == null) return;
    await _runAction(
      () => ref
          .read(adminApiProvider)
          .createUser(
            username: input.username,
            displayName: input.displayName,
            temporaryPassword: input.temporaryPassword,
            role: input.role,
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final users = _users;
    return AdminGuard(
      child: Scaffold(
        backgroundColor: colors.background,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              ClayHeader(
                title: 'Utilisateurs',
                onBack: () => Navigator.of(context).maybePop(),
                actions: [
                  SoftCircle(
                    size: 46,
                    onTap: _loading ? null : _refresh,
                    tooltip: 'Actualiser',
                    semanticLabel: 'Actualiser',
                    child: _loading
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: colors.textSecondary,
                            ),
                          )
                        : Icon(
                            Icons.refresh_rounded,
                            size: 21,
                            color: colors.textPrimary,
                          ),
                  ),
                ],
              ),
              Expanded(
                child: RefreshIndicator(
                  color: colors.accent,
                  backgroundColor: colors.surface,
                  onRefresh: _refresh,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(
                      AppLayout.gutter,
                      4,
                      AppLayout.gutter,
                      96,
                    ),
                    children: [
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            _error!,
                            style: TextStyle(color: colors.danger, fontSize: 13),
                          ),
                        ),
                      if (users == null && _error == null)
                        Padding(
                          padding: const EdgeInsets.only(top: 48),
                          child: Center(
                            child: CircularProgressIndicator(
                              color: colors.accent,
                            ),
                          ),
                        ),
                      if (users != null)
                        for (final user in users)
                          _UserCard(user: user, onAction: (a) => _onAction(user, a)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          backgroundColor: colors.accent,
          foregroundColor: colors.onAccent,
          onPressed: _createUser,
          icon: const Icon(Icons.person_add_rounded),
          label: const Text('Nouveau compte'),
        ),
      ),
    );
  }
}

enum _UserAction {
  block,
  unblock,
  revokeSessions,
  resetPassword,
  toggleRole,
  delete,
}

class _UserCard extends StatelessWidget {
  const _UserCard({required this.user, required this.onAction});

  final AdminUser user;
  final ValueChanged<_UserAction> onAction;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SoftCard(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          user.displayName,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.textPrimary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _RoleChip(role: user.role),
                      if (!user.isActive) ...[
                        const SizedBox(width: 6),
                        _Badge('Bloqué', colors.danger),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '@${user.username}',
                    style: TextStyle(color: colors.textSecondary, fontSize: 13),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Dernière connexion : ${formatDateTime(user.lastLoginAt)}',
                    style: TextStyle(color: colors.textTertiary, fontSize: 12),
                  ),
                  Text(
                    'Stockage : '
                    '${user.storageUsage == null ? 'non calculé' : formatBytes(user.storageUsage)}',
                    style: TextStyle(color: colors.textTertiary, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (user.isOwner)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Icon(
                  Icons.shield_rounded,
                  color: colors.accent,
                  size: 20,
                ),
              )
            else
              PopupMenuButton<_UserAction>(
                color: colors.surfaceRaised,
                iconColor: colors.textSecondary,
                shape: RoundedRectangleBorder(
                  borderRadius: AppRadius.cardRadius,
                ),
                onSelected: onAction,
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: user.isActive
                        ? _UserAction.block
                        : _UserAction.unblock,
                    child: _menuText(
                      colors,
                      user.isActive ? 'Bloquer' : 'Réactiver',
                    ),
                  ),
                  PopupMenuItem(
                    value: _UserAction.revokeSessions,
                    child: _menuText(colors, 'Révoquer les sessions'),
                  ),
                  PopupMenuItem(
                    value: _UserAction.resetPassword,
                    child: _menuText(colors, 'Réinitialiser le mot de passe'),
                  ),
                  PopupMenuItem(
                    value: _UserAction.toggleRole,
                    child: _menuText(
                      colors,
                      user.role == 'ADMIN'
                          ? 'Rétrograder en USER'
                          : 'Promouvoir ADMIN',
                    ),
                  ),
                  PopupMenuItem(
                    value: _UserAction.delete,
                    child: Text(
                      'Supprimer',
                      style: TextStyle(color: colors.danger),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  static Text _menuText(AppColors colors, String label) =>
      Text(label, style: TextStyle(color: colors.textPrimary));
}

class _RoleChip extends StatelessWidget {
  const _RoleChip({required this.role});

  final String role;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final color = switch (role) {
      'OWNER' => colors.accent,
      'ADMIN' => colors.link,
      _ => colors.textTertiary,
    };
    return _Badge(role, color);
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.label, this.color);

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Dialogue autonome (L-019 : possède ses contrôleurs et son cycle de vie).
class _TemporaryPasswordDialog extends StatefulWidget {
  const _TemporaryPasswordDialog();

  static Future<String?> show(BuildContext context) {
    return showDialog<String>(
      context: context,
      builder: (_) => const _TemporaryPasswordDialog(),
    );
  }

  @override
  State<_TemporaryPasswordDialog> createState() =>
      _TemporaryPasswordDialogState();
}

class _TemporaryPasswordDialogState extends State<_TemporaryPasswordDialog> {
  final _password = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AlertDialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(borderRadius: AppRadius.cardRadius),
      title: Text(
        'Mot de passe temporaire',
        style: TextStyle(color: colors.textPrimary),
      ),
      content: TextField(
        controller: _password,
        autofocus: true,
        style: TextStyle(color: colors.textPrimary),
        decoration: InputDecoration(
          labelText: '10 caractères minimum',
          labelStyle: TextStyle(color: colors.textSecondary),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Annuler', style: TextStyle(color: colors.textSecondary)),
        ),
        TextButton(
          onPressed: () {
            final value = _password.text;
            if (value.length >= 10) Navigator.of(context).pop(value);
          },
          child: Text('Réinitialiser', style: TextStyle(color: colors.accent)),
        ),
      ],
    );
  }
}

class _CreateUserInput {
  const _CreateUserInput({
    required this.username,
    required this.displayName,
    required this.temporaryPassword,
    required this.role,
  });

  final String username;
  final String displayName;
  final String temporaryPassword;
  final String role;
}

/// Dialogue autonome de création de compte (jamais de rôle OWNER proposé).
class _CreateUserDialog extends StatefulWidget {
  const _CreateUserDialog();

  static Future<_CreateUserInput?> show(BuildContext context) {
    return showDialog<_CreateUserInput>(
      context: context,
      builder: (_) => const _CreateUserDialog(),
    );
  }

  @override
  State<_CreateUserDialog> createState() => _CreateUserDialogState();
}

class _CreateUserDialogState extends State<_CreateUserDialog> {
  final _username = TextEditingController();
  final _displayName = TextEditingController();
  final _password = TextEditingController();
  String _role = 'USER';

  @override
  void dispose() {
    _username.dispose();
    _displayName.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    if (_username.text.trim().isEmpty ||
        _displayName.text.trim().isEmpty ||
        _password.text.length < 10) {
      return;
    }
    Navigator.of(context).pop(
      _CreateUserInput(
        username: _username.text.trim(),
        displayName: _displayName.text.trim(),
        temporaryPassword: _password.text,
        role: _role,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AlertDialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(borderRadius: AppRadius.cardRadius),
      title: Text('Nouveau compte', style: TextStyle(color: colors.textPrimary)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _username,
            autofocus: true,
            style: TextStyle(color: colors.textPrimary),
            decoration: InputDecoration(
              labelText: 'Nom d’utilisateur',
              labelStyle: TextStyle(color: colors.textSecondary),
            ),
          ),
          TextField(
            controller: _displayName,
            style: TextStyle(color: colors.textPrimary),
            decoration: InputDecoration(
              labelText: 'Nom affiché',
              labelStyle: TextStyle(color: colors.textSecondary),
            ),
          ),
          TextField(
            controller: _password,
            style: TextStyle(color: colors.textPrimary),
            decoration: InputDecoration(
              labelText: 'Mot de passe temporaire (10 min.)',
              labelStyle: TextStyle(color: colors.textSecondary),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Text('Rôle', style: TextStyle(color: colors.textSecondary)),
              const Spacer(),
              DropdownButton<String>(
                value: _role,
                dropdownColor: colors.surfaceRaised,
                style: TextStyle(color: colors.textPrimary),
                items: const [
                  DropdownMenuItem(value: 'USER', child: Text('USER')),
                  DropdownMenuItem(value: 'ADMIN', child: Text('ADMIN')),
                ],
                onChanged: (value) => setState(() => _role = value ?? 'USER'),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Annuler', style: TextStyle(color: colors.textSecondary)),
        ),
        TextButton(
          onPressed: _submit,
          child: Text('Créer', style: TextStyle(color: colors.accent)),
        ),
      ],
    );
  }
}
