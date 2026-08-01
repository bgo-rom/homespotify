import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/logging/app_logger.dart';
import '../data/admin_api.dart';
import 'admin_guard.dart';

/// Tableau de bord OWNER : état du serveur, stockage, bibliothèque, comptes.
class AdminDashboardScreen extends ConsumerStatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  ConsumerState<AdminDashboardScreen> createState() =>
      _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends ConsumerState<AdminDashboardScreen> {
  AdminOverview? _overview;
  String? _error;
  bool _loading = false;
  bool _maintenanceRunning = false;
  DateTime? _refreshedAt;

  @override
  void initState() {
    super.initState();
    logUi('ouverture Administration/Tableau de bord');
    _refresh();
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final overview = await ref.read(adminApiProvider).fetchOverview();
      if (!mounted) return;
      setState(() {
        _overview = overview;
        _refreshedAt = DateTime.now();
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

  Future<void> _runMaintenance(
    Future<void> Function(AdminApi api) action,
    String successMessage,
  ) async {
    if (_maintenanceRunning) return;
    setState(() => _maintenanceRunning = true);
    try {
      await action(ref.read(adminApiProvider));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(successMessage)),
      );
      await _refresh();
    } on AdminApiException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message), backgroundColor: adminError),
      );
    } finally {
      if (mounted) setState(() => _maintenanceRunning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final overview = _overview;
    return AdminGuard(
      child: Scaffold(
        backgroundColor: adminBackground,
        appBar: AppBar(
          backgroundColor: adminBackground,
          foregroundColor: Colors.white,
          title: const Text(
            'Administration',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          actions: [
            IconButton(
              tooltip: 'Actualiser',
              onPressed: _loading ? null : _refresh,
              icon: _loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white54,
                      ),
                    )
                  : const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body: RefreshIndicator(
          color: adminAccent,
          onRefresh: _refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: adminError, fontSize: 13),
                  ),
                ),
              if (overview == null && _error == null)
                const Padding(
                  padding: EdgeInsets.only(top: 48),
                  child: Center(
                    child: CircularProgressIndicator(color: adminAccent),
                  ),
                ),
              if (overview != null) ...[
                _AdminSection(
                  title: 'Serveur',
                  rows: [
                    (
                      'État',
                      overview.backendStatus == 'ok'
                          ? 'En ligne'
                          : 'Hors ligne',
                    ),
                    ('Uptime', formatUptime(overview.uptimeSeconds)),
                    ('Version', overview.version),
                    ('Heure serveur', formatDateTime(overview.serverTime)),
                  ],
                ),
                _AdminSection(
                  title: 'Stockage',
                  rows: [
                    ('Total', formatBytes(overview.diskTotalBytes)),
                    ('Utilisé', formatBytes(overview.diskUsedBytes)),
                    ('Libre', formatBytes(overview.diskFreeBytes)),
                    (
                      'Bibliothèque audio',
                      formatBytes(overview.librarySizeBytes),
                    ),
                    ('Pistes', '${overview.libraryTrackCount}'),
                  ],
                ),
                _AdminSection(
                  title: 'Comptes',
                  rows: [
                    ('Utilisateurs', '${overview.totalUsers}'),
                    ('Actifs', '${overview.activeUsers}'),
                    ('Bloqués', '${overview.blockedUsers}'),
                    ('Sessions actives', '${overview.activeSessions}'),
                  ],
                ),
                _AdminSection(
                  title: 'Santé opérationnelle',
                  rows: [
                    (
                      'État global',
                      switch (overview.operationsStatus) {
                        'healthy' => 'Sain',
                        'degraded' => 'À surveiller',
                        'critical' => 'Critique',
                        _ => 'Inconnu',
                      },
                    ),
                    ('Erreurs audio (24 h)', '${overview.audioErrors24h}'),
                    ('Imports échoués', '${overview.failedImports}'),
                    ('Fichiers suspects', '${overview.suspectFiles}'),
                    ('Fichiers absents', '${overview.missingFiles}'),
                    (
                      'Tailles incohérentes',
                      '${overview.inconsistentSizeFiles}',
                    ),
                    ('Chemins invalides', '${overview.invalidPathFiles}'),
                  ],
                ),
                _AdminSection(
                  title: 'Sauvegarde quotidienne',
                  rows: [
                    (
                      'État',
                      !overview.backupEnabled
                          ? 'Désactivée'
                          : overview.backupRunning
                          ? 'En cours'
                          : overview.backupLastError != null
                          ? 'Erreur'
                          : 'Planifiée',
                    ),
                    (
                      'Dernier succès',
                      overview.backupLastSuccessAt == null
                          ? 'Jamais'
                          : formatDateTime(overview.backupLastSuccessAt!),
                    ),
                    (
                      'Prochaine',
                      overview.backupNextRunAt == null
                          ? 'Non planifiée'
                          : formatDateTime(overview.backupNextRunAt!),
                    ),
                    ('Rétention', '${overview.backupRetentionCount} sauvegardes'),
                    if (overview.backupLastError != null)
                      ('Dernière erreur', overview.backupLastError!),
                  ],
                ),
                _AdminSection(
                  title: 'Détection du stockage par profil',
                  rows: [
                    (
                      'Scanner',
                      overview.scannerRunning ? 'Analyse en cours' : 'Prêt',
                    ),
                    ('Imports actifs', '${overview.scannerActiveImports}'),
                    ('En attente', '${overview.scannerQueuedImports}'),
                    (
                      'Dernier scan',
                      overview.scannerLastCompletedAt == null
                          ? 'Jamais'
                          : formatDateTime(overview.scannerLastCompletedAt!),
                    ),
                    if (overview.scannerLastError != null)
                      ('Dernière erreur', overview.scannerLastError!),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed:
                            _maintenanceRunning || !overview.backupEnabled
                            ? null
                            : () => _runMaintenance(
                                (api) => api.runBackup(),
                                'Sauvegarde terminée.',
                              ),
                        icon: const Icon(Icons.backup_rounded),
                        label: const Text('Sauvegarder'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _maintenanceRunning
                            ? null
                            : () => _runMaintenance(
                                (api) => api.scanStorage(),
                                'Stockage analysé.',
                              ),
                        icon: const Icon(Icons.manage_search_rounded),
                        label: const Text('Scanner'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: adminAccent,
                      foregroundColor: Colors.black,
                    ),
                    onPressed: () => context.push('/admin/users'),
                    icon: const Icon(Icons.group_rounded),
                    label: const Text('Gérer les utilisateurs'),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => context.push('/admin/imports'),
                        icon: const Icon(Icons.move_to_inbox_rounded),
                        label: const Text('Imports'),
                      ),
                    ),
                  ],
                ),
                if (_refreshedAt != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      'Dernière actualisation : '
                      '${formatDateTime(_refreshedAt!.toIso8601String())}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _AdminSection extends StatelessWidget {
  const _AdminSection({required this.title, required this.rows});

  final String title;
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              title,
              style: const TextStyle(
                color: adminAccent,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: adminCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white10),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  for (final (label, value) in rows)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              label,
                              style: const TextStyle(color: Colors.white54),
                            ),
                          ),
                          Text(
                            value,
                            style: const TextStyle(color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
