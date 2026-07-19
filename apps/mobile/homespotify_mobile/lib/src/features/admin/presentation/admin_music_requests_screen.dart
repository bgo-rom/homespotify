import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/external_url_launcher.dart';
import '../data/admin_api.dart';
import 'admin_guard.dart';

const _statuses = <String>[
  'SENT',
  'REVIEWING',
  'APPROVED',
  'SEARCHING_MANUALLY',
  'IMPORTING',
  'REJECTED',
  'FAILED',
];

class AdminMusicRequestsScreen extends ConsumerStatefulWidget {
  const AdminMusicRequestsScreen({super.key});

  @override
  ConsumerState<AdminMusicRequestsScreen> createState() =>
      _AdminMusicRequestsScreenState();
}

class _AdminMusicRequestsScreenState
    extends ConsumerState<AdminMusicRequestsScreen>
    with SingleTickerProviderStateMixin {
  List<AdminMusicRequest> _items = const [];
  bool _loading = true;
  String? _error;
  String _query = '';
  String? _type;
  int? _userId;
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 6, vsync: this)
      ..addListener(() => setState(() {}));
    _refresh();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  List<AdminMusicRequest> get _filtered {
    Iterable<AdminMusicRequest> values = switch (_tabs.index) {
      1 => _items.where((item) => item.status == 'SENT'),
      2 => _items.where(
        (item) => const [
          'REVIEWING',
          'APPROVED',
          'SEARCHING_MANUALLY',
          'IMPORTING',
        ].contains(item.status),
      ),
      3 => _items.where(
        (item) =>
            const ['PARTIALLY_COMPLETED', 'COMPLETED'].contains(item.status),
      ),
      4 => _items.where((item) => item.status == 'REJECTED'),
      5 => _items.where((item) => item.status == 'FAILED'),
      _ => _items,
    };
    if (_type != null) values = values.where((item) => item.itemType == _type);
    if (_userId != null) {
      values = values.where((item) => item.requesterId == _userId);
    }
    final query = _query.trim().toLowerCase();
    if (query.isNotEmpty) {
      values = values.where(
        (item) => [
          item.title,
          item.artist,
          item.album ?? '',
          item.requesterName,
          item.requesterUsername,
        ].join(' ').toLowerCase().contains(query),
      );
    }
    return values.toList(growable: false);
  }

  Future<void> _refresh() async {
    try {
      final items = await ref.read(adminApiProvider).listMusicRequests();
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

  Future<void> _open(AdminMusicRequest item) async {
    await showDialog<void>(
      context: context,
      builder: (_) =>
          _RequestDialog(item: item, api: ref.read(adminApiProvider)),
    );
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final users = <int, String>{
      for (final item in _items) item.requesterId: item.requesterName,
    };
    return AdminGuard(
      child: Scaffold(
        backgroundColor: adminBackground,
        appBar: AppBar(
          backgroundColor: adminBackground,
          foregroundColor: Colors.white,
          title: const Text('Demandes musicales'),
          bottom: TabBar(
            controller: _tabs,
            isScrollable: true,
            labelColor: adminAccent,
            unselectedLabelColor: Colors.white54,
            tabs: const [
              Tab(text: 'Toutes'),
              Tab(text: 'Envoyées'),
              Tab(text: 'En cours'),
              Tab(text: 'Terminées'),
              Tab(text: 'Refusées'),
              Tab(text: 'Échecs'),
            ],
          ),
          actions: [
            IconButton(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator(color: adminAccent))
            : _error != null
            ? Center(
                child: Text(_error!, style: const TextStyle(color: adminError)),
              )
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                    child: TextField(
                      key: const Key('admin-request-search'),
                      onChanged: (value) => setState(() => _query = value),
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search_rounded),
                        hintText: 'Titre, artiste, album ou utilisateur',
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String?>(
                            initialValue: _type,
                            dropdownColor: adminCard,
                            items: const [
                              DropdownMenuItem(
                                value: null,
                                child: Text('Tous les types'),
                              ),
                              DropdownMenuItem(
                                value: 'TRACK',
                                child: Text('Morceaux'),
                              ),
                              DropdownMenuItem(
                                value: 'ALBUM',
                                child: Text('Albums'),
                              ),
                              DropdownMenuItem(
                                value: 'PLAYLIST',
                                child: Text('Playlists'),
                              ),
                            ],
                            onChanged: (value) => setState(() => _type = value),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: DropdownButtonFormField<int?>(
                            initialValue: _userId,
                            dropdownColor: adminCard,
                            items: [
                              const DropdownMenuItem(
                                value: null,
                                child: Text('Tous les utilisateurs'),
                              ),
                              for (final entry in users.entries)
                                DropdownMenuItem(
                                  value: entry.key,
                                  child: Text(entry.value),
                                ),
                            ],
                            onChanged: (value) =>
                                setState(() => _userId = value),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: _filtered.isEmpty
                        ? const Center(
                            child: Text(
                              'Aucune demande.',
                              style: TextStyle(color: Colors.white54),
                            ),
                          )
                        : ListView(
                            padding: const EdgeInsets.all(12),
                            children: [
                              for (final item in _filtered)
                                _RequestCard(
                                  item: item,
                                  onTap: () => _open(item),
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

class _RequestCard extends StatelessWidget {
  const _RequestCard({required this.item, required this.onTap});

  final AdminMusicRequest item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
    color: adminCard,
    child: ListTile(
      onTap: onTap,
      title: Text(
        '${item.title} — ${item.artist}',
        style: const TextStyle(color: Colors.white),
      ),
      subtitle: Text(
        '${item.requesterName} · ${item.itemType} · ${formatDateTime(item.createdAt)}\n'
        '${item.album ?? 'Album inconnu'} · ${item.status} · '
        '${item.completedItemCount}/${item.requestedItemCount}',
        style: const TextStyle(color: Colors.white54),
      ),
      trailing: Icon(
        item.presentInRequesterLibrary
            ? Icons.library_add_check_rounded
            : Icons.chevron_right_rounded,
        color: item.presentInRequesterLibrary ? adminAccent : Colors.white38,
      ),
    ),
  );
}

class _RequestDialog extends StatefulWidget {
  const _RequestDialog({required this.item, required this.api});

  final AdminMusicRequest item;
  final AdminApi api;

  @override
  State<_RequestDialog> createState() => _RequestDialogState();
}

class _RequestDialogState extends State<_RequestDialog> {
  late final TextEditingController _note = TextEditingController(
    text: widget.item.ownerNote,
  );
  final _trackSearch = TextEditingController();
  late String _status =
      const ['COMPLETED', 'PARTIALLY_COMPLETED'].contains(widget.item.status)
      ? 'IMPORTING'
      : widget.item.status;
  bool _busy = false;
  bool _searching = false;
  List<AdminTrackSearchResult> _trackResults = const [];
  AdminMusicRequestItem? _selectedItem;

  @override
  void dispose() {
    _note.dispose();
    _trackSearch.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
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
    final query = _trackSearch.text.trim();
    if (query.length < 2 || _searching) return;
    setState(() => _searching = true);
    try {
      final results = await widget.api.searchTracks(query);
      if (mounted) setState(() => _trackResults = results);
    } on AdminApiException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _openExternalUrl() async {
    final url = widget.item.externalUrl;
    if (url == null) return;
    final opened = await const ExternalUrlLauncher().open(url);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Impossible d\'ouvrir ce lien.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: adminCard,
    title: Text(widget.item.title, style: const TextStyle(color: Colors.white)),
    content: SizedBox(
      width: 620,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.item.requesterName} · ${widget.item.itemType}\n'
              '${widget.item.artist} · ${widget.item.album ?? 'Album inconnu'}',
              style: const TextStyle(color: Colors.white70),
            ),
            if ((widget.item.userNote ?? '').isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Note : ${widget.item.userNote}',
                style: const TextStyle(color: Colors.white60),
              ),
            ],
            if (widget.item.externalUrl != null) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                key: const Key('open-request-external-url'),
                onPressed: _openExternalUrl,
                icon: const Icon(Icons.open_in_new_rounded),
                label: Text(
                  widget.item.externalUrl!,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              'Progression : ${widget.item.completedItemCount}/${widget.item.requestedItemCount}',
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 8),
            RadioGroup<AdminMusicRequestItem>(
              groupValue: _selectedItem,
              onChanged: (value) => setState(() => _selectedItem = value),
              child: Column(
                children: [
                  for (final item in widget.item.items)
                    RadioListTile<AdminMusicRequestItem>(
                      value: item,
                      activeColor: adminAccent,
                      title: Text(
                        '${item.position}. ${item.title}',
                        style: const TextStyle(color: Colors.white),
                      ),
                      subtitle: Text(
                        '${item.artist ?? 'Artiste inconnu'} · ${item.status}',
                        style: const TextStyle(color: Colors.white54),
                      ),
                      secondary: Icon(
                        item.presentInRequesterLibrary
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        color: item.presentInRequesterLibrary
                            ? adminAccent
                            : Colors.white24,
                      ),
                    ),
                ],
              ),
            ),
            const Divider(color: Colors.white12),
            TextField(
              key: const Key('admin-track-search-field'),
              controller: _trackSearch,
              onSubmitted: (_) => _searchTracks(),
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: 'Rechercher une piste existante',
                suffixIcon: IconButton(
                  onPressed: _searching ? null : _searchTracks,
                  icon: _searching
                      ? const CircularProgressIndicator(strokeWidth: 2)
                      : const Icon(Icons.search_rounded),
                ),
              ),
            ),
            for (final track in _trackResults)
              ListTile(
                title: Text(
                  track.title,
                  style: const TextStyle(color: Colors.white),
                ),
                subtitle: Text(
                  '${track.artist} · ${track.album}',
                  style: const TextStyle(color: Colors.white54),
                ),
                trailing: FilledButton(
                  onPressed: _busy || _selectedItem == null
                      ? null
                      : () => _run(
                          () => widget.api.assignTrack(
                            widget.item.id,
                            _selectedItem!.id,
                            track.id,
                          ),
                        ),
                  child: const Text('Associer'),
                ),
              ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _statuses.contains(_status) ? _status : 'REVIEWING',
              dropdownColor: adminCard,
              style: const TextStyle(color: Colors.white),
              items: [
                for (final status in _statuses)
                  DropdownMenuItem(value: status, child: Text(status)),
              ],
              onChanged: (value) => _status = value ?? _status,
              decoration: const InputDecoration(
                labelText: 'Statut (complétion automatique)',
              ),
            ),
            TextField(
              controller: _note,
              maxLines: 3,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(labelText: 'Note OWNER'),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy
            ? null
            : () =>
                  _run(() => widget.api.reconcileMusicRequest(widget.item.id)),
        child: const Text('Réconcilier'),
      ),
      FilledButton(
        onPressed: _busy
            ? null
            : () => _run(
                () => widget.api.updateMusicRequest(
                  widget.item.id,
                  status: _status,
                  ownerNote: _note.text,
                ),
              ),
        child: const Text('Enregistrer'),
      ),
    ],
  );
}
