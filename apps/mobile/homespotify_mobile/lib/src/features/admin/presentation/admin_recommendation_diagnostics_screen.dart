import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shapes.dart';
import '../../../core/widgets/clay_header.dart';
import '../../../core/widgets/soft_surface.dart';
import '../data/admin_api.dart';
import '../presentation/widgets/admin_section.dart';
import 'admin_guard.dart';

/// Diagnostics techniques du moteur de recommandations (OWNER).
///
/// Remplace l'ancien « Catalogue de recommandations » manuel : le catalogue
/// est désormais alimenté par le job asynchrone. Cet écran n'expose que des
/// compteurs, l'état du provider externe et un déclencheur de maintenance.
class AdminRecommendationDiagnosticsScreen extends ConsumerStatefulWidget {
  const AdminRecommendationDiagnosticsScreen({super.key});

  @override
  ConsumerState<AdminRecommendationDiagnosticsScreen> createState() =>
      _AdminRecommendationDiagnosticsScreenState();
}

class _AdminRecommendationDiagnosticsScreenState
    extends ConsumerState<AdminRecommendationDiagnosticsScreen> {
  AdminRecommendationHealth? _health;
  AdminRecommendationMetrics? _metrics;
  bool _loading = true;
  bool _maintenanceBusy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ref.read(adminApiProvider);
      final health = await api.fetchRecommendationHealth();
      final metrics = await api.fetchRecommendationMetrics();
      if (!mounted) return;
      setState(() {
        _health = health;
        _metrics = metrics;
        _loading = false;
      });
    } on AdminApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.message;
      });
    }
  }

  Future<void> _runMaintenance() async {
    if (_maintenanceBusy) return;
    setState(() => _maintenanceBusy = true);
    try {
      final users = await ref
          .read(adminApiProvider)
          .triggerRecommendationMaintenance();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Maintenance lancée : régénération pour $users compte(s).',
          ),
        ),
      );
      await _refresh();
    } on AdminApiException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } finally {
      if (mounted) setState(() => _maintenanceBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AdminGuard(
      child: Scaffold(
        backgroundColor: colors.background,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              ClayHeader(
                title: 'Diagnostics recommandations',
                onBack: () => Navigator.of(context).maybePop(),
                actions: [
                  SoftCircle(
                    size: 46,
                    onTap: _loading ? null : _refresh,
                    tooltip: 'Recharger les diagnostics',
                    semanticLabel: 'Recharger les diagnostics',
                    child: Icon(
                      Icons.refresh_rounded,
                      size: 21,
                      color: colors.textPrimary,
                    ),
                  ),
                ],
              ),
              Expanded(child: _buildBody(colors)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(AppColors colors) {
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: colors.accent));
    }
    final error = _error;
    if (error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(error, style: TextStyle(color: colors.textSecondary)),
            const SizedBox(height: 12),
            FilledButton(onPressed: _refresh, child: const Text('Réessayer')),
          ],
        ),
      );
    }
    final health = _health;
    final metrics = _metrics;
    if (health == null || metrics == null) return const SizedBox.shrink();
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppLayout.gutter,
        4,
        AppLayout.gutter,
        32,
      ),
      children: [
        AdminSection(
          title: 'État du moteur',
          children: [
            AdminInfoRow(
              label: 'Statut',
              value: health.degraded ? 'Dégradé' : 'OK',
              valueColor: health.degraded ? colors.danger : colors.accent,
            ),
            AdminInfoRow(
              label: 'Version du modèle',
              value: health.modelVersion,
            ),
            AdminInfoRow(
              label: 'Dernière génération',
              value: health.lastGeneratedAt ?? 'Jamais',
            ),
            if (health.providerErrorMessage != null)
              AdminInfoRow(
                label: 'Erreur provider',
                value:
                    '${health.providerErrorMessage} (${health.providerErrorAt ?? '?'})',
                valueColor: colors.danger,
              )
            else
              const AdminInfoRow(label: 'Erreur provider', value: 'Aucune'),
          ],
        ),
        AdminSection(
          title: 'Candidats (catalogue global)',
          children: [
            AdminInfoRow(label: 'Total', value: '${health.candidatesTotal}'),
            AdminInfoRow(label: 'Actifs', value: '${health.candidatesActive}'),
            AdminInfoRow(
              label: 'Avec extrait audio',
              value: '${health.candidatesWithPreview}',
            ),
          ],
        ),
        AdminSection(
          title: 'Files par compte',
          children: [
            AdminInfoRow(
              label: 'Comptes avec file',
              value: '${health.usersWithQueue}',
            ),
            AdminInfoRow(
              label: 'Entrées totales',
              value: '${health.queueEntries}',
            ),
          ],
        ),
        AdminSection(
          title: 'Usage',
          children: [
            for (final action in const [
              'LIKE',
              'DISLIKE',
              'SKIP',
              'REQUEST',
              'OPEN',
            ])
              AdminInfoRow(
                label: action,
                value: '${metrics.actions[action] ?? 0}',
              ),
            AdminInfoRow(
              label: 'Impressions (24 h)',
              value: '${metrics.impressions24h}',
            ),
            AdminInfoRow(
              label: 'Impressions (total)',
              value: '${metrics.impressionsTotal}',
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: colors.accent,
              foregroundColor: colors.onAccent,
              shape: RoundedRectangleBorder(borderRadius: AppRadius.chipRadius),
            ),
            onPressed: _maintenanceBusy ? null : _runMaintenance,
            icon: _maintenanceBusy
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colors.onAccent,
                    ),
                  )
                : const Icon(Icons.build_rounded),
            label: const Text('Lancer une maintenance'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
            'Régénère la file de recommandations de tous les comptes actifs '
            '(job asynchrone côté serveur, protégé contre les exécutions '
            'concurrentes).',
            style: TextStyle(color: colors.textTertiary, fontSize: 12.5),
          ),
        ),
      ],
    );
  }
}
