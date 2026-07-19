import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../library/data/library_api.dart';
import '../data/discovery_api.dart';
import '../domain/discovery_models.dart';

const Color _bg = Color(0xFF0D0D10);
const Color _card = Color(0xFF1A1A22);
const Color _accent = Color(0xFF1DB954);

/// Intervalle de polling léger, uniquement quand cet écran est visible et
/// l'application au premier plan (pas de WebSocket/SSE, choix assumé).
const Duration _pollInterval = Duration(seconds: 4);

/// Écran « Mes demandes » : liste des demandes du compte courant, statuts
/// métier lisibles, note du propriétaire, annulation avant import.
class MusicRequestsScreen extends ConsumerStatefulWidget {
  const MusicRequestsScreen({super.key});

  @override
  ConsumerState<MusicRequestsScreen> createState() =>
      _MusicRequestsScreenState();
}

class _MusicRequestsScreenState extends ConsumerState<MusicRequestsScreen>
    with WidgetsBindingObserver {
  List<MusicRequest> _requests = const [];
  bool _loading = true;
  String? _error;
  Timer? _pollTimer;
  bool _fetchInFlight = false;
  final Set<int> _cancelling = <int>{};

  @override
  void initState() {
    super.initState();
    logUi('ouverture mes demandes');
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    _startPolling();
  }

  @override
  void dispose() {
    _stopPolling();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Pause du polling en arrière-plan, reprise + refresh au retour au
    // premier plan.
    if (state == AppLifecycleState.resumed) {
      logUi('mes demandes: reprise du polling (app au premier plan)');
      _refresh();
      _startPolling();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _stopPolling();
    }
  }

  void _startPolling() {
    _pollTimer ??= Timer.periodic(_pollInterval, (_) => _refresh(silent: true));
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _refresh({bool silent = false}) async {
    if (_fetchInFlight) return;
    _fetchInFlight = true;
    if (!silent && mounted) {
      setState(() {
        _loading = _requests.isEmpty;
        _error = null;
      });
    }
    try {
      final items = await ref.read(discoveryApiProvider).fetchRequests();
      if (!mounted) return;
      _detectCompletions(previous: _requests, next: items);
      setState(() {
        _requests = items;
        _loading = false;
        _error = null;
      });
    } on DiscoveryApiException catch (error) {
      if (!mounted) return;
      // En polling silencieux, ne pas écraser la liste affichée par une
      // erreur transitoire.
      setState(() {
        _loading = false;
        if (!silent || _requests.isEmpty) _error = error.message;
      });
    } finally {
      _fetchInFlight = false;
    }
  }

  /// Une demande vient de passer COMPLETED : la bibliothèque locale est
  /// rechargée immédiatement (la piste attribuée doit apparaître sans geste).
  void _detectCompletions({
    required List<MusicRequest> previous,
    required List<MusicRequest> next,
  }) {
    final previousStatuses = {for (final r in previous) r.id: r.status};
    final justCompleted = next.where(
      (r) =>
          r.status == MusicRequestStatus.completed &&
          previousStatuses[r.id] != null &&
          previousStatuses[r.id] != MusicRequestStatus.completed,
    );
    if (justCompleted.isEmpty) return;
    logUi(
      'demande(s) complétée(s): '
      '${justCompleted.map((r) => r.id).join(', ')} — refresh bibliothèque',
    );
    ref.invalidate(libraryProvider);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            justCompleted.length == 1
                ? '« ${justCompleted.first.title} » a été ajouté à ta bibliothèque.'
                : '${justCompleted.length} demandes viennent d\'aboutir.',
          ),
        ),
      );
    }
  }

  Future<void> _cancel(MusicRequest request) async {
    if (_cancelling.contains(request.id)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _card,
        title: const Text(
          'Annuler la demande ?',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          '« ${request.title} » de ${request.artist} ne sera pas traité.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(
              'Garder',
              style: TextStyle(color: Colors.white54),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFE57373),
              foregroundColor: Colors.black,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Annuler la demande'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _cancelling.add(request.id));
    try {
      final updated = await ref
          .read(discoveryApiProvider)
          .cancelRequest(request.id);
      if (!mounted) return;
      setState(() {
        _requests = [
          for (final r in _requests) r.id == updated.id ? updated : r,
        ];
      });
    } on DiscoveryApiException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
      // L'état serveur a peut-être bougé (import démarré) : resynchroniser.
      _refresh(silent: true);
    } finally {
      if (mounted) setState(() => _cancelling.remove(request.id));
    }
  }

  Future<void> _createRequest() async {
    final created = await showDialog<MusicRequest>(
      context: context,
      builder: (_) =>
          _CreateMusicRequestDialog(repository: ref.read(discoveryApiProvider)),
    );
    if (created == null || !mounted) return;
    setState(() => _requests = [created, ..._requests]);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Demande envoyée.')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: Colors.white,
        title: const Text(
          'Mes demandes',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('create-music-request'),
        backgroundColor: _accent,
        foregroundColor: Colors.black,
        onPressed: _createRequest,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Nouvelle demande'),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _accent));
    }
    if (_error != null && _requests.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.cloud_off_rounded,
                size: 64,
                color: Colors.white24,
              ),
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 15),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.black,
                ),
                onPressed: _refresh,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Réessayer'),
              ),
            ],
          ),
        ),
      );
    }
    if (_requests.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.inbox_rounded, size: 64, color: Colors.white24),
              SizedBox(height: 16),
              Text(
                'Aucune demande pour le moment.\n'
                'Swipe à droite dans « Découvrir » pour en envoyer une.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 15),
              ),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      color: _accent,
      backgroundColor: _bg,
      onRefresh: () => _refresh(),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _requests.length,
        itemBuilder: (context, index) {
          final request = _requests[index];
          return _RequestTile(
            request: request,
            cancelling: _cancelling.contains(request.id),
            onCancel: request.status.isCancellable
                ? () => _cancel(request)
                : null,
          );
        },
      ),
    );
  }
}

class _RequestTile extends StatelessWidget {
  const _RequestTile({
    required this.request,
    required this.cancelling,
    required this.onCancel,
  });

  final MusicRequest request;
  final bool cancelling;
  final VoidCallback? onCancel;

  Color get _statusColor => switch (request.status) {
    MusicRequestStatus.partiallyCompleted => const Color(0xFF67D68A),
    MusicRequestStatus.completed => _accent,
    MusicRequestStatus.rejected ||
    MusicRequestStatus.failed => const Color(0xFFE57373),
    MusicRequestStatus.cancelled => Colors.white38,
    _ => const Color(0xFFFFC94D),
  };

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: request.artworkUrl == null
                      ? const ColoredBox(
                          color: Color(0xFF23232B),
                          child: Icon(
                            Icons.music_note_rounded,
                            color: Colors.white24,
                          ),
                        )
                      : Image.network(
                          request.artworkUrl!,
                          fit: BoxFit.cover,
                          cacheWidth: 96,
                          cacheHeight: 96,
                          errorBuilder: (_, _, _) => const ColoredBox(
                            color: Color(0xFF23232B),
                            child: Icon(
                              Icons.music_note_rounded,
                              color: Colors.white24,
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      request.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        request.artist,
                        if ((request.album ?? '').isNotEmpty) request.album!,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              if (onCancel != null)
                cancelling
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          color: _accent,
                        ),
                      )
                    : IconButton(
                        tooltip: 'Annuler la demande',
                        icon: const Icon(
                          Icons.close_rounded,
                          color: Colors.white54,
                        ),
                        onPressed: onCancel,
                      ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _statusColor.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  request.status.label,
                  style: TextStyle(
                    color: _statusColor,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                request.requestType.label,
                style: const TextStyle(color: Colors.white38, fontSize: 11.5),
              ),
            ],
          ),
          if (request.requestedItemCount > 0) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: request.completedItemCount / request.requestedItemCount,
              minHeight: 4,
              borderRadius: BorderRadius.circular(4),
              backgroundColor: Colors.white12,
              color: _statusColor,
            ),
            const SizedBox(height: 4),
            Text(
              '${request.completedItemCount}/${request.requestedItemCount} ajoutés',
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
          if ((request.ownerNote ?? '').isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Note du propriétaire : ${request.ownerNote}',
              style: const TextStyle(
                color: Colors.white60,
                fontSize: 12.5,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _CreateMusicRequestDialog extends StatefulWidget {
  const _CreateMusicRequestDialog({required this.repository});

  final DiscoveryRepository repository;

  @override
  State<_CreateMusicRequestDialog> createState() =>
      _CreateMusicRequestDialogState();
}

class _CreateMusicRequestDialogState extends State<_CreateMusicRequestDialog> {
  final _title = TextEditingController();
  final _artist = TextEditingController();
  final _album = TextEditingController();
  final _externalUrl = TextEditingController();
  final _note = TextEditingController();
  final _items = TextEditingController();
  MusicRequestType _type = MusicRequestType.track;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    _album.dispose();
    _externalUrl.dispose();
    _note.dispose();
    _items.dispose();
    super.dispose();
  }

  List<MusicRequestDraftItem> _parseItems() => _items.text
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .map((line) {
        final parts = line.split('|').map((part) => part.trim()).toList();
        return MusicRequestDraftItem(
          title: parts.first,
          artist: parts.length > 1 && parts[1].isNotEmpty ? parts[1] : null,
          album: parts.length > 2 && parts[2].isNotEmpty ? parts[2] : null,
        );
      })
      .toList(growable: false);

  Future<void> _submit() async {
    if (_busy) return;
    final title = _title.text.trim();
    final externalUrl = _externalUrl.text.trim();
    final items = _parseItems();
    if (title.isEmpty) {
      setState(() => _error = 'Le titre est obligatoire.');
      return;
    }
    if (_type == MusicRequestType.playlist &&
        externalUrl.isEmpty &&
        items.isEmpty) {
      setState(
        () => _error = 'Ajoutez le lien de la playlist ou sa liste de titres.',
      );
      return;
    }
    final uri = Uri.tryParse(externalUrl);
    if (externalUrl.isNotEmpty &&
        (uri == null || (uri.scheme != 'http' && uri.scheme != 'https'))) {
      setState(
        () => _error = 'Le lien doit commencer par http:// ou https://.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final created = await widget.repository.createCustomRequest(
        MusicRequestDraft(
          requestType: _type,
          title: title,
          artist: _artist.text.trim().isEmpty ? null : _artist.text.trim(),
          album: _album.text.trim().isEmpty ? null : _album.text.trim(),
          externalUrl: externalUrl.isEmpty ? null : externalUrl,
          userNote: _note.text.trim().isEmpty ? null : _note.text.trim(),
          items: items,
        ),
      );
      if (mounted) Navigator.of(context).pop(created);
    } on DiscoveryApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: _card,
    title: const Text(
      'Nouvelle demande',
      style: TextStyle(color: Colors.white),
    ),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<MusicRequestType>(
            initialValue: _type,
            dropdownColor: _card,
            style: const TextStyle(color: Colors.white),
            items: [
              for (final type in MusicRequestType.values)
                DropdownMenuItem(value: type, child: Text(type.label)),
            ],
            onChanged: _busy
                ? null
                : (value) => setState(() => _type = value ?? _type),
            decoration: const InputDecoration(labelText: 'Type'),
          ),
          TextField(
            key: const Key('request-title'),
            controller: _title,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: _type == MusicRequestType.playlist
                  ? 'Nom de la playlist'
                  : 'Titre',
            ),
          ),
          TextField(
            controller: _artist,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(labelText: 'Artiste'),
          ),
          TextField(
            controller: _album,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(labelText: 'Album'),
          ),
          TextField(
            key: const Key('request-external-url'),
            controller: _externalUrl,
            keyboardType: TextInputType.url,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              labelText: 'Lien externe',
              hintText: 'https://...',
            ),
          ),
          if (_type != MusicRequestType.track)
            TextField(
              key: const Key('request-items'),
              controller: _items,
              minLines: 2,
              maxLines: 6,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Titres (un par ligne)',
                hintText: 'Titre | Artiste | Album',
              ),
            ),
          TextField(
            controller: _note,
            maxLines: 2,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(labelText: 'Note facultative'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: const TextStyle(color: Color(0xFFE57373))),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.of(context).pop(),
        child: const Text('Annuler'),
      ),
      FilledButton(
        key: const Key('submit-music-request'),
        onPressed: _busy ? null : _submit,
        child: _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('Envoyer'),
      ),
    ],
  );
}
