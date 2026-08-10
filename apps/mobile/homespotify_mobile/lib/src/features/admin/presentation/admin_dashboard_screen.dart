import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shapes.dart';
import '../../../core/widgets/clay_header.dart';
import '../../../core/widgets/soft_surface.dart';
import '../data/admin_api.dart';
import '../presentation/widgets/admin_section.dart';
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
        SnackBar(
          content: Text(error.message),
          backgroundColor: context.colors.danger,
        ),
      );
    } finally {
      if (mounted) setState(() => _maintenanceRunning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final overview = _overview;
    return AdminGuard(
      child: Scaffold(
        backgroundColor: colors.background,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              ClayHeader(
                title: 'Administration',
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
                      32,
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
                      if (overview == null && _error == null)
                        Padding(
                          padding: const EdgeInsets.only(top: 48),
                          child: Center(
                            child: CircularProgressIndicator(
                              color: colors.accent,
                            ),
                          ),
                        ),
                      if (overview != null) ...[
                        AdminSection(
                          title: 'Serveur',
                          children: [
                            AdminInfoRow(
                              label: 'État',
                              value: overview.backendStatus == 'ok'
                                  ? 'En ligne'
                                  : 'Hors ligne',
                            ),
                            AdminInfoRow(
                              label: 'Uptime',
                              value: formatUptime(overview.uptimeSeconds),
                            ),
                            AdminInfoRow(
                              label: 'Version',
                              value: overview.version,
                            ),
                            AdminInfoRow(
                              label: 'Heure serveur',
                              value: formatDateTime(overview.serverTime),
                            ),
                          ],
                        ),
                        AdminSection(
                          title: 'Stockage',
                          children: [
                            AdminInfoRow(
                              label: 'Total',
                              value: formatBytes(overview.diskTotalBytes),
                            ),
                            AdminInfoRow(
                              label: 'Utilisé',
                              value: formatBytes(overview.diskUsedBytes),
                            ),
                            AdminInfoRow(
                              label: 'Libre',
                              value: formatBytes(overview.diskFreeBytes),
                            ),
                            AdminInfoRow(
                              label: 'Bibliothèque audio',
                              value: formatBytes(overview.librarySizeBytes),
                            ),
                            AdminInfoRow(
                              label: 'Pistes',
                              value: '${overview.libraryTrackCount}',
                            ),
                          ],
                        ),
                        AdminSection(
                          title: 'Comptes',
                          children: [
                            AdminInfoRow(
                              label: 'Utilisateurs',
                              value: '${overview.totalUsers}',
                            ),
                            AdminInfoRow(
                              label: 'Actifs',
                              value: '${overview.activeUsers}',
                            ),
                            AdminInfoRow(
                              label: 'Bloqués',
                              value: '${overview.blockedUsers}',
                            ),
                            AdminInfoRow(
                              label: 'Sessions actives',
                              value: '${overview.activeSessions}',
                            ),
                          ],
                        ),
                        AdminSection(
                          title: 'Santé opérationnelle',
                          children: [
                            AdminInfoRow(
                              label: 'État global',
                              value: switch (overview.operationsStatus) {
                                'healthy' => 'Sain',
                                'degraded' => 'À surveiller',
                                'critical' => 'Critique',
                                _ => 'Inconnu',
                              },
                              valueColor: switch (overview.operationsStatus) {
                                'healthy' => colors.accent,
                                'critical' => colors.danger,
                                _ => null,
                              },
                            ),
                            AdminInfoRow(
                              label: 'Erreurs audio (24 h)',
                              value: '${overview.audioErrors24h}',
                            ),
                            AdminInfoRow(
                              label: 'Imports échoués',
                              value: '${overview.failedImports}',
                            ),
                            AdminInfoRow(
                              label: 'Fichiers suspects',
                              value: '${overview.suspectFiles}',
                            ),
                            AdminInfoRow(
                              label: 'Fichiers absents',
                              value: '${overview.missingFiles}',
                            ),
                            AdminInfoRow(
                              label: 'Tailles incohérentes',
                              value: '${overview.inconsistentSizeFiles}',
                            ),
                            AdminInfoRow(
                              label: 'Chemins invalides',
                              value: '${overview.invalidPathFiles}',
                            ),
                          ],
                        ),
                        AdminSection(
                          title: 'Sauvegarde quotidienne',
                          children: [
                            AdminInfoRow(
                              label: 'État',
                              value: !overview.backupEnabled
                                  ? 'Désactivée'
                                  : overview.backupRunning
                                  ? 'En cours'
                                  : overview.backupLastError != null
                                  ? 'Erreur'
                                  : 'Planifiée',
                            ),
                            AdminInfoRow(
                              label: 'Dernier succès',
                              value: overview.backupLastSuccessAt == null
                                  ? 'Jamais'
                                  : formatDateTime(
                                      overview.backupLastSuccessAt!,
                                    ),
                            ),
                            AdminInfoRow(
                              label: 'Prochaine',
                              value: overview.backupNextRunAt == null
                                  ? 'Non planifiée'
                                  : formatDateTime(overview.backupNextRunAt!),
                            ),
                            AdminInfoRow(
                              label: 'Rétention',
                              value:
                                  '${overview.backupRetentionCount} sauvegardes',
                            ),
                            if (overview.backupLastError != null)
                              AdminInfoRow(
                                label: 'Dernière erreur',
                                value: overview.backupLastError!,
                                valueColor: colors.danger,
                              ),
                          ],
                        ),
                        AdminSection(
                          title: 'Détection du stockage par profil',
                          children: [
                            AdminInfoRow(
                              label: 'Scanner',
                              value: overview.scannerRunning
                                  ? 'Analyse en cours'
                                  : 'Prêt',
                            ),
                            AdminInfoRow(
                              label: 'Imports actifs',
                              value: '${overview.scannerActiveImports}',
                            ),
                            AdminInfoRow(
                              label: 'En attente',
                              value: '${overview.scannerQueuedImports}',
                            ),
                            AdminInfoRow(
                              label: 'Dernier scan',
                              value: overview.scannerLastCompletedAt == null
                                  ? 'Jamais'
                                  : formatDateTime(
                                      overview.scannerLastCompletedAt!,
                                    ),
                            ),
                            if (overview.scannerLastError != null)
                              AdminInfoRow(
                                label: 'Dernière erreur',
                                value: overview.scannerLastError!,
                                valueColor: colors.danger,
                              ),
                          ],
                        ),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: colors.accent,
                                  side: BorderSide(color: colors.accent),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: AppRadius.chipRadius,
                                  ),
                                ),
                                onPressed:
                                    _maintenanceRunning ||
                                        !overview.backupEnabled
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
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: colors.accent,
                                  side: BorderSide(color: colors.accent),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: AppRadius.chipRadius,
                                  ),
                                ),
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
                              backgroundColor: colors.accent,
                              foregroundColor: colors.onAccent,
                              shape: RoundedRectangleBorder(
                                borderRadius: AppRadius.chipRadius,
                              ),
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
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: colors.accent,
                                  side: BorderSide(color: colors.accent),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: AppRadius.chipRadius,
                                  ),
                                ),
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
                              style: TextStyle(
                                color: colors.textTertiary,
                                fontSize: 12,
                              ),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
