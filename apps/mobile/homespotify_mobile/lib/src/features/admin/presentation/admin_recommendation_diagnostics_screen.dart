import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/admin_api.dart';
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
  Widget build(BuildContext context) => AdminGuard(
    child: Scaffold(
      backgroundColor: adminBackground,
      appBar: AppBar(
        backgroundColor: adminBackground,
        foregroundColor: Colors.white,
        title: const Text('Diagnostics recommandations'),
        actions: [
          IconButton(
            tooltip: 'Recharger les diagnostics',
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _buildBody(),
    ),
  );

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: adminAccent));
    }
    final error = _error;
    if (error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(error, style: const TextStyle(color: Colors.white70)),
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
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        _section('État du moteur', [
          _row(
            'Statut',
            health.degraded ? 'Dégradé' : 'OK',
            valueColor: health.degraded ? adminError : adminAccent,
          ),
          _row('Version du modèle', health.modelVersion),
          _row('Dernière génération', health.lastGeneratedAt ?? 'Jamais'),
          if (health.providerErrorMessage != null)
            _row(
              'Erreur provider',
              '${health.providerErrorMessage} (${health.providerErrorAt ?? '?'})',
              valueColor: adminError,
            )
          else
            _row('Erreur provider', 'Aucune'),
        ]),
        _section('Candidats (catalogue global)', [
          _row('Total', '${health.candidatesTotal}'),
          _row('Actifs', '${health.candidatesActive}'),
          _row('Avec extrait audio', '${health.candidatesWithPreview}'),
        ]),
        _section('Files par compte', [
          _row('Comptes avec file', '${health.usersWithQueue}'),
          _row('Entrées totales', '${health.queueEntries}'),
        ]),
        _section('Usage', [
          for (final action in const [
            'LIKE',
            'DISLIKE',
            'SKIP',
            'REQUEST',
            'OPEN',
          ])
            _row(action, '${metrics.actions[action] ?? 0}'),
          _row('Impressions (24 h)', '${metrics.impressions24h}'),
          _row('Impressions (total)', '${metrics.impressionsTotal}'),
        ]),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: adminAccent,
              foregroundColor: Colors.black,
            ),
            onPressed: _maintenanceBusy ? null : _runMaintenance,
            icon: _maintenanceBusy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.black54,
                    ),
                  )
                : const Icon(Icons.build_rounded),
            label: const Text('Lancer une maintenance'),
          ),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 10),
          child: Text(
            'Régénère la file de recommandations de tous les comptes actifs '
            '(job asynchrone côté serveur, protégé contre les exécutions '
            'concurrentes).',
            style: TextStyle(color: Colors.white54, fontSize: 12.5),
          ),
        ),
      ],
    );
  }

  Widget _section(String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
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
              child: Column(children: children),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 4,
            child: Text(label, style: const TextStyle(color: Colors.white54)),
          ),
          const SizedBox(width: 16),
          Expanded(
            flex: 5,
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: TextStyle(color: valueColor ?? Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}
