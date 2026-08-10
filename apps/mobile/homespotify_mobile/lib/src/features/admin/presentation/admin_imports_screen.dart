import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shapes.dart';
import '../../../core/widgets/clay_header.dart';
import '../../../core/widgets/soft_surface.dart';
import '../data/admin_api.dart';
import 'admin_guard.dart';

const _importStatuses = <String>[
  'DISCOVERED',
  'WAITING_FOR_STABLE_FILE',
  'ANALYZING',
  'WAITING_FOR_OWNER_MATCH',
  'IMPORTED',
  'REUSED',
  'REJECTED',
  'FAILED',
];

class AdminImportsScreen extends ConsumerStatefulWidget {
  const AdminImportsScreen({super.key});

  @override
  ConsumerState<AdminImportsScreen> createState() => _AdminImportsScreenState();
}

class _AdminImportsScreenState extends ConsumerState<AdminImportsScreen> {
  List<AdminImportJob> _items = const [];
  bool _loading = true;
  String? _error;
  String? _status;
  int? _userId;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final items = await ref.read(adminApiProvider).listImports();
      if (mounted) {
        setState(() {
          _items = items;
          _loading = false;
          _error = null;
        });
      }
    } on AdminApiException catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = error.message;
        });
      }
    }
  }

  List<AdminImportJob> get _filtered => _items
      .where((item) {
        if (_status != null && item.status != _status) return false;
        if (_userId != null && item.userId != _userId) return false;
        return true;
      })
      .toList(growable: false);

  Future<void> _open(AdminImportJob job) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _ImportDialog(job: job, api: ref.read(adminApiProvider)),
    );
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final users = <int, String>{
      for (final item in _items) item.userId: item.requesterName,
    };
    return AdminGuard(
      child: Scaffold(
        backgroundColor: colors.background,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              ClayHeader(
                title: 'Imports utilisateurs',
                onBack: () => Navigator.of(context).maybePop(),
                actions: [
                  SoftCircle(
                    size: 46,
                    onTap: _refresh,
                    tooltip: 'Actualiser',
                    semanticLabel: 'Actualiser',
                    child: Icon(
                      Icons.refresh_rounded,
                      size: 21,
                      color: colors.textPrimary,
                    ),
                  ),
                ],
              ),
              Expanded(
                child: _loading
                    ? Center(child: CircularProgressIndicator(color: colors.accent))
                    : _error != null
                    ? Center(
                        child: Text(
                          _error!,
                          style: TextStyle(color: colors.danger),
                        ),
                      )
                    : Column(
                        children: [
                          _Filters(
                            status: _status,
                            userId: _userId,
                            users: users,
                            onStatusChanged: (value) =>
                                setState(() => _status = value),
                            onUserChanged: (value) =>
                                setState(() => _userId = value),
                          ),
                          Expanded(
                            child: _filtered.isEmpty
                                ? Center(
                                    child: Text(
                                      'Aucun import enregistré.',
                                      style: TextStyle(
                                        color: colors.textSecondary,
                                      ),
                                    ),
                                  )
                                : ListView.builder(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: AppLayout.gutter - 10,
                                    ),
                                    itemCount: _filtered.length,
                                    itemBuilder: (context, index) {
                                      final item = _filtered[index];
                                      return Padding(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 5,
                                        ),
                                        child: SoftCard(
                                          onTap: () => _open(item),
                                          child: ListTile(
                                            leading: Icon(
                                              Icons.audio_file_rounded,
                                              color: colors.accent,
                                            ),
                                            title: Text(
                                              item.filename,
                                              style: TextStyle(
                                                color: colors.textPrimary,
                                              ),
                                            ),
                                            subtitle: Text(
                                              '${item.requesterName} · ${item.status}\n${item.relativePath}',
                                              style: TextStyle(
                                                color: colors.textSecondary,
                                              ),
                                            ),
                                            trailing: Icon(
                                              Icons.chevron_right_rounded,
                                              color: colors.textTertiary,
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ImportDialog extends StatefulWidget {
  const _ImportDialog({required this.job, required this.api});

  final AdminImportJob job;
  final AdminApi api;

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final _search = TextEditingController();
  List<AdminTrackSearchResult> _tracks = const [];
  AdminTrackSearchResult? _track;
  bool _busy = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _perform(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) Navigator.of(context).pop();
    } on AdminApiException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _searchTracks() async {
    final query = _search.text.trim();
    if (query.length < 2 || _busy) return;
    setState(() => _busy = true);
    try {
      final tracks = await widget.api.searchTracks(query);
      if (mounted) setState(() => _tracks = tracks);
    } on AdminApiException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final metadata = widget.job.metadata ?? const <String, dynamic>{};
    return AlertDialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(borderRadius: AppRadius.cardRadius),
      title: Text(
        widget.job.filename,
        style: TextStyle(color: colors.textPrimary),
      ),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${widget.job.requesterName} · ${widget.job.status}\n'
                '${widget.job.sizeBytes ?? 0} octets\n'
                'Dossier : ${widget.job.directoryPath}\n'
                'Fichier : ${widget.job.relativePath}',
                style: TextStyle(color: colors.textSecondary),
              ),
              if (metadata.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  '${metadata['title'] ?? 'Titre inconnu'} · '
                  '${metadata['artist'] ?? 'Artiste inconnu'}\n'
                  '${metadata['album'] ?? 'Album inconnu'} · '
                  '${metadata['container'] ?? '?'}',
                  style: TextStyle(color: colors.textSecondary),
                ),
              ],
              if (widget.job.errorMessage != null) ...[
                const SizedBox(height: 10),
                Text(
                  widget.job.errorMessage!,
                  style: TextStyle(color: colors.danger),
                ),
              ],
              Divider(color: colors.surfaceSunken, height: 28),
              TextField(
                key: const Key('import-track-search'),
                controller: _search,
                onSubmitted: (_) => _searchTracks(),
                style: TextStyle(color: colors.textPrimary),
                decoration: InputDecoration(
                  labelText: 'Rechercher une piste',
                  suffixIcon: IconButton(
                    onPressed: _busy ? null : _searchTracks,
                    icon: const Icon(Icons.search_rounded),
                  ),
                ),
              ),
              RadioGroup<AdminTrackSearchResult>(
                groupValue: _track,
                onChanged: (value) => setState(() => _track = value),
                child: Column(
                  children: [
                    for (final track in _tracks)
                      RadioListTile<AdminTrackSearchResult>(
                        value: track,
                        activeColor: colors.accent,
                        title: Text(
                          track.title,
                          style: TextStyle(color: colors.textPrimary),
                        ),
                        subtitle: Text(
                          '${track.artist} · ${track.album}',
                          style: TextStyle(color: colors.textSecondary),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy
              ? null
              : () => _perform(() => widget.api.retryImport(widget.job.id)),
          child: const Text('Réessayer'),
        ),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: colors.danger),
          onPressed: _busy
              ? null
              : () => _perform(() => widget.api.rejectImport(widget.job.id)),
          child: const Text('Déplacer vers rejected'),
        ),
      ],
    );
  }
}

/// Filtres du panel Imports, RESPONSIVE.
///
/// Cause de l'overflow d'origine : deux [DropdownButtonFormField] côte à côte
/// dans un Row sans `isExpanded`. La largeur intrinsèque d'un dropdown est
/// dictée par son item le plus long (« Tous les utilisateurs ») : il refuse
/// donc de rétrécir sous la largeur disponible, d'où le débordement sur
/// téléphone étroit. Correctifs : `isExpanded: true` (le dropdown occupe la
/// largeur donnée et ellipse proprement) + disposition en colonne sous 600 dp.
class _Filters extends StatelessWidget {
  const _Filters({
    required this.status,
    required this.userId,
    required this.users,
    required this.onStatusChanged,
    required this.onUserChanged,
  });

  /// Seuil de bascule Row → Column (téléphone étroit vs tablette/paysage).
  static const double _wideBreakpoint = 600;

  final String? status;
  final int? userId;
  final Map<int, String> users;
  final ValueChanged<String?> onStatusChanged;
  final ValueChanged<int?> onUserChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final statusFilter = DropdownButtonFormField<String?>(
      // Sans isExpanded, le dropdown garde la largeur de son plus long item.
      isExpanded: true,
      initialValue: status,
      dropdownColor: colors.surfaceRaised,
      decoration: const InputDecoration(labelText: 'Statut', isDense: true),
      items: [
        const DropdownMenuItem(
          value: null,
          child: Text('Tous les statuts', overflow: TextOverflow.ellipsis),
        ),
        for (final value in _importStatuses)
          DropdownMenuItem(
            value: value,
            child: Text(value, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: onStatusChanged,
    );
    final userFilter = DropdownButtonFormField<int?>(
      isExpanded: true,
      initialValue: userId,
      dropdownColor: colors.surfaceRaised,
      decoration: const InputDecoration(
        labelText: 'Utilisateur',
        isDense: true,
      ),
      items: [
        const DropdownMenuItem(
          value: null,
          child: Text('Tous les utilisateurs', overflow: TextOverflow.ellipsis),
        ),
        for (final entry in users.entries)
          DropdownMenuItem(
            value: entry.key,
            child: Text(entry.value, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: onUserChanged,
    );

    return Padding(
      padding: const EdgeInsets.all(12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < _wideBreakpoint) {
            // Écran étroit : empilés, chacun sur toute la largeur disponible.
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [statusFilter, const SizedBox(height: 8), userFilter],
            );
          }
          return Row(
            children: [
              Expanded(child: statusFilter),
              const SizedBox(width: 8),
              Expanded(child: userFilter),
            ],
          );
        },
      ),
    );
  }
}
