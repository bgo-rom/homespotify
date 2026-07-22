import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/external_url_launcher.dart';
import '../data/admin_api.dart';
import 'admin_guard.dart';

const _activeStatuses = <String>{
  'REVIEWING',
  'APPROVED',
  'SEARCHING_MANUALLY',
  'IMPORTING',
};
const _completedStatuses = <String>{'PARTIALLY_COMPLETED', 'COMPLETED'};

String _statusLabel(String status) => switch (status) {
  'SENT' => 'À traiter',
  'REVIEWING' => 'En examen',
  'APPROVED' => 'Approuvée',
  'SEARCHING_MANUALLY' => 'Recherche en cours',
  'IMPORTING' => 'Import en cours',
  'PARTIALLY_COMPLETED' => 'Partiellement terminée',
  'COMPLETED' => 'Terminée',
  'REJECTED' => 'Refusée',
  'FAILED' => 'Échec',
  'CANCELLED' => 'Annulée',
  _ => 'Statut inconnu',
};

Color _statusColor(String status) => switch (status) {
  'SENT' => const Color(0xFFFFB74D),
  'REVIEWING' || 'APPROVED' => const Color(0xFF64B5F6),
  'SEARCHING_MANUALLY' || 'IMPORTING' => const Color(0xFFBA68C8),
  'PARTIALLY_COMPLETED' || 'COMPLETED' => adminAccent,
  'REJECTED' || 'FAILED' => adminError,
  _ => Colors.white54,
};

String _typeLabel(String type) => switch (type) {
  'TRACK' => 'Morceau',
  'ALBUM' => 'Album',
  'PLAYLIST' => 'Playlist',
  _ => 'Musique',
};

IconData _typeIcon(String type) => switch (type) {
  'ALBUM' => Icons.album_rounded,
  'PLAYLIST' => Icons.queue_music_rounded,
  _ => Icons.music_note_rounded,
};

String _itemStatusLabel(String status) => switch (status) {
  'PENDING' => 'À associer',
  'MATCHED' || 'COMPLETED' => 'Associé',
  'UNAVAILABLE' => 'Indisponible',
  _ => _statusLabel(status),
};

class AdminMusicRequestsScreen extends ConsumerStatefulWidget {
  const AdminMusicRequestsScreen({super.key});

  @override
  ConsumerState<AdminMusicRequestsScreen> createState() =>
      _AdminMusicRequestsScreenState();
}

class _AdminMusicRequestsScreenState
    extends ConsumerState<AdminMusicRequestsScreen>
    with SingleTickerProviderStateMixin {
  final _search = TextEditingController();
  late final TabController _tabs;
  List<AdminMusicRequest> _items = const [];
  bool _loading = true;
  String? _error;
  String _query = '';
  String? _type;
  int? _userId;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this)..addListener(_tabChanged);
    _refresh();
  }

  @override
  void dispose() {
    _search.dispose();
    _tabs
      ..removeListener(_tabChanged)
      ..dispose();
    super.dispose();
  }

  void _tabChanged() {
    if (!_tabs.indexIsChanging && mounted) setState(() {});
  }

  Iterable<AdminMusicRequest> _forTab(int index) => switch (index) {
    0 => _items.where((item) => item.status == 'SENT'),
    1 => _items.where((item) => _activeStatuses.contains(item.status)),
    2 => _items.where((item) => _completedStatuses.contains(item.status)),
    _ => _items,
  };

  List<AdminMusicRequest> get _filtered {
    var values = _forTab(_tabs.index);
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
    if (mounted) setState(() => _loading = true);
    try {
      final items = await ref.read(adminApiProvider).listMusicRequests();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
        _error = null;
      });
    } on AdminApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.message;
      });
    }
  }

  Future<void> _open(AdminMusicRequest item) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            _RequestDetailScreen(item: item, api: ref.read(adminApiProvider)),
      ),
    );
    await _refresh();
  }

  Future<void> _showFilters() async {
    final users = <int, String>{
      for (final item in _items) item.requesterId: item.requesterName,
    };
    var selectedType = _type;
    var selectedUser = _userId;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: adminCard,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Filtrer les demandes',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 18),
                const Text('Type', style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final entry in const <String?, String>{
                      null: 'Tous',
                      'TRACK': 'Morceaux',
                      'ALBUM': 'Albums',
                      'PLAYLIST': 'Playlists',
                    }.entries)
                      ChoiceChip(
                        label: Text(entry.value),
                        selected: selectedType == entry.key,
                        onSelected: (_) =>
                            setSheetState(() => selectedType = entry.key),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<int?>(
                  initialValue: selectedUser,
                  dropdownColor: adminCard,
                  decoration: const InputDecoration(labelText: 'Utilisateur'),
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
                      setSheetState(() => selectedUser = value),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          setState(() {
                            _type = null;
                            _userId = null;
                          });
                          Navigator.pop(sheetContext);
                        },
                        child: const Text('Réinitialiser'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: () {
                          setState(() {
                            _type = selectedType;
                            _userId = selectedUser;
                          });
                          Navigator.pop(sheetContext);
                        },
                        child: const Text('Appliquer'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pending = _items.where((item) => item.status == 'SENT').length;
    final active = _items
        .where((item) => _activeStatuses.contains(item.status))
        .length;
    final completed = _items
        .where((item) => _completedStatuses.contains(item.status))
        .length;
    final hasFilters = _type != null || _userId != null;
    return AdminGuard(
      child: Scaffold(
        backgroundColor: adminBackground,
        appBar: AppBar(
          backgroundColor: adminBackground,
          foregroundColor: Colors.white,
          title: const Text('Demandes'),
          actions: [
            IconButton(
              tooltip: 'Actualiser',
              onPressed: _loading ? null : _refresh,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body: _loading && _items.isEmpty
            ? const Center(child: CircularProgressIndicator(color: adminAccent))
            : _error != null && _items.isEmpty
            ? _ErrorState(message: _error!, onRetry: _refresh)
            : RefreshIndicator(
                onRefresh: _refresh,
                color: adminAccent,
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: _CounterCard(
                                    label: 'À traiter',
                                    value: pending,
                                    color: _statusColor('SENT'),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: _CounterCard(
                                    label: 'En cours',
                                    value: active,
                                    color: _statusColor('REVIEWING'),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: _CounterCard(
                                    label: 'Terminées',
                                    value: completed,
                                    color: adminAccent,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    key: const Key('admin-request-search'),
                                    controller: _search,
                                    onChanged: (value) =>
                                        setState(() => _query = value),
                                    style: const TextStyle(color: Colors.white),
                                    decoration: InputDecoration(
                                      prefixIcon: const Icon(
                                        Icons.search_rounded,
                                      ),
                                      hintText: 'Titre, artiste ou utilisateur',
                                      suffixIcon: _query.isEmpty
                                          ? null
                                          : IconButton(
                                              onPressed: () {
                                                _search.clear();
                                                setState(() => _query = '');
                                              },
                                              icon: const Icon(
                                                Icons.close_rounded,
                                              ),
                                            ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Badge(
                                  isLabelVisible: hasFilters,
                                  smallSize: 9,
                                  backgroundColor: adminAccent,
                                  child: IconButton.filledTonal(
                                    tooltip: 'Filtres',
                                    onPressed: _showFilters,
                                    icon: const Icon(Icons.tune_rounded),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: _TabHeaderDelegate(
                        TabBar(
                          controller: _tabs,
                          isScrollable: true,
                          tabAlignment: TabAlignment.start,
                          labelColor: adminAccent,
                          unselectedLabelColor: Colors.white54,
                          dividerColor: Colors.transparent,
                          tabs: [
                            Tab(text: 'À traiter ($pending)'),
                            Tab(text: 'En cours ($active)'),
                            Tab(text: 'Terminées ($completed)'),
                            Tab(text: 'Toutes (${_items.length})'),
                          ],
                        ),
                      ),
                    ),
                    if (_filtered.isEmpty)
                      const SliverFillRemaining(
                        hasScrollBody: false,
                        child: _EmptyState(),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
                        sliver: SliverList.separated(
                          itemCount: _filtered.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 10),
                          itemBuilder: (context, index) {
                            final item = _filtered[index];
                            return _RequestCard(
                              item: item,
                              onTap: () => _open(item),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _TabHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _TabHeaderDelegate(this.tabBar);

  final TabBar tabBar;

  @override
  double get minExtent => 48;

  @override
  double get maxExtent => 48;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => ColoredBox(color: adminBackground, child: tabBar);

  @override
  bool shouldRebuild(_TabHeaderDelegate oldDelegate) =>
      oldDelegate.tabBar != tabBar;
}

class _CounterCard extends StatelessWidget {
  const _CounterCard({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    decoration: BoxDecoration(
      color: adminCard,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: color.withValues(alpha: .22)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$value',
          style: TextStyle(
            color: color,
            fontSize: 22,
            fontWeight: FontWeight.w800,
          ),
        ),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white60, fontSize: 12),
        ),
      ],
    ),
  );
}

class _RequestCard extends StatelessWidget {
  const _RequestCard({required this.item, required this.onTap});

  final AdminMusicRequest item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(item.status);
    final total = item.requestedItemCount;
    final progress = total == 0 ? 0.0 : item.completedItemCount / total;
    return Material(
      color: adminCard,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Artwork(
                url: item.artworkUrl,
                icon: _typeIcon(item.itemType),
                size: 68,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const Icon(
                          Icons.chevron_right_rounded,
                          color: Colors.white30,
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white60),
                    ),
                    const SizedBox(height: 9),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _StatusPill(
                          label: _statusLabel(item.status),
                          color: color,
                        ),
                        _StatusPill(
                          label: _typeLabel(item.itemType),
                          color: Colors.white54,
                        ),
                      ],
                    ),
                    const SizedBox(height: 9),
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 10,
                          backgroundColor: adminAccent.withValues(alpha: .18),
                          child: Text(
                            item.requesterName.isEmpty
                                ? '?'
                                : item.requesterName[0].toUpperCase(),
                            style: const TextStyle(
                              color: adminAccent,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '${item.requesterName} · ${formatDateTime(item.createdAt)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (total > 1) ...[
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(3),
                              child: LinearProgressIndicator(
                                value: progress.clamp(0, 1),
                                minHeight: 5,
                                color: color,
                                backgroundColor: Colors.white10,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${item.completedItemCount}/$total',
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ],
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

class _RequestDetailScreen extends StatefulWidget {
  const _RequestDetailScreen({required this.item, required this.api});

  final AdminMusicRequest item;
  final AdminApi api;

  @override
  State<_RequestDetailScreen> createState() => _RequestDetailScreenState();
}

class _RequestDetailScreenState extends State<_RequestDetailScreen> {
  late final _note = TextEditingController(text: widget.item.ownerNote);
  final _trackSearch = TextEditingController();
  late String _status = _completedStatuses.contains(widget.item.status)
      ? 'IMPORTING'
      : widget.item.status;
  AdminMusicRequestItem? _selectedItem;
  List<AdminTrackSearchResult> _trackResults = const [];
  AdminSpotifyLink? _spotifyLink;
  bool _busy = false;
  bool _searching = false;
  bool _resolvingSpotify = false;

  @override
  void dispose() {
    _note.dispose();
    _trackSearch.dispose();
    super.dispose();
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _run(Future<void> Function() action, {bool close = true}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (mounted && close) Navigator.of(context).pop();
    } on AdminApiException catch (error) {
      _message(error.message);
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
      _message(error.message);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _openExternalUrl() async {
    final url = widget.item.externalUrl;
    if (url == null) return;
    if (!await const ExternalUrlLauncher().open(url)) {
      _message('Impossible d’ouvrir ce lien.');
    }
  }

  Future<void> _resolveSpotifyLink() async {
    if (_resolvingSpotify) return;
    setState(() => _resolvingSpotify = true);
    try {
      final link = await widget.api.resolveSpotifyLink(widget.item.id);
      if (!mounted) return;
      setState(() => _spotifyLink = link);
      _message(
        link.exact
            ? 'Lien Spotify exact trouvé.'
            : 'API Spotify non configurée : recherche préremplie prête.',
      );
    } on AdminApiException catch (error) {
      _message(error.message);
    } finally {
      if (mounted) setState(() => _resolvingSpotify = false);
    }
  }

  Future<void> _openSpotifyLink() async {
    final link = _spotifyLink;
    if (link == null) return;
    if (!await const ExternalUrlLauncher().open(link.url)) {
      _message('Impossible d’ouvrir Spotify.');
    }
  }

  Future<void> _copySpotifyLink() async {
    final link = _spotifyLink;
    if (link == null) return;
    await Clipboard.setData(ClipboardData(text: link.url));
    _message('Lien Spotify copié.');
  }

  Future<void> _reconcile() =>
      _run(() => widget.api.reconcileMusicRequest(widget.item.id));

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: adminBackground,
    appBar: AppBar(
      backgroundColor: adminBackground,
      foregroundColor: Colors.white,
      title: const Text('Détail de la demande'),
      actions: [
        PopupMenuButton<String>(
          tooltip: 'Plus d’actions',
          onSelected: (value) {
            if (value == 'reconcile') _reconcile();
          },
          itemBuilder: (_) => const [
            PopupMenuItem(
              value: 'reconcile',
              child: ListTile(
                leading: Icon(Icons.sync_rounded),
                title: Text('Vérifier automatiquement'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ],
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                _RequestHero(item: widget.item, onOpenLink: _openExternalUrl),
                const SizedBox(height: 12),
                _SpotifyLinkCard(
                  link: _spotifyLink,
                  loading: _resolvingSpotify,
                  onResolve: _resolveSpotifyLink,
                  onOpen: _openSpotifyLink,
                  onCopy: _copySpotifyLink,
                ),
                const SizedBox(height: 22),
                const _SectionTitle(
                  icon: Icons.route_rounded,
                  title: 'Étape actuelle',
                  subtitle: 'Choisis l’état qui décrit vraiment l’avancement.',
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final entry in const <String, String>{
                      'REVIEWING': 'Examiner',
                      'APPROVED': 'Approuver',
                      'SEARCHING_MANUALLY': 'Rechercher',
                      'IMPORTING': 'Importer',
                      'REJECTED': 'Refuser',
                      'FAILED': 'Échec',
                    }.entries)
                      ChoiceChip(
                        label: Text(entry.value),
                        selected: _status == entry.key,
                        onSelected: _busy
                            ? null
                            : (_) => setState(() => _status = entry.key),
                      ),
                  ],
                ),
                const SizedBox(height: 24),
                _SectionTitle(
                  icon: Icons.format_list_numbered_rounded,
                  title: widget.item.items.length == 1
                      ? 'Titre demandé'
                      : '${widget.item.items.length} titres demandés',
                  subtitle:
                      'Sélectionne un titre pour l’associer à la bibliothèque.',
                ),
                const SizedBox(height: 10),
                for (final item in widget.item.items)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Material(
                      color: _selectedItem?.id == item.id
                          ? adminAccent.withValues(alpha: .12)
                          : adminCard,
                      borderRadius: BorderRadius.circular(14),
                      child: ListTile(
                        onTap: item.presentInRequesterLibrary
                            ? null
                            : () => setState(() {
                                _selectedItem = item;
                                if (_trackSearch.text.isEmpty) {
                                  _trackSearch.text = [
                                    item.title,
                                    item.artist,
                                  ].whereType<String>().join(' ');
                                }
                              }),
                        leading: Icon(
                          item.presentInRequesterLibrary
                              ? Icons.check_circle_rounded
                              : _selectedItem?.id == item.id
                              ? Icons.radio_button_checked_rounded
                              : Icons.radio_button_unchecked_rounded,
                          color:
                              item.presentInRequesterLibrary ||
                                  _selectedItem?.id == item.id
                              ? adminAccent
                              : Colors.white30,
                        ),
                        title: Text(
                          '${item.position}. ${item.title}',
                          style: const TextStyle(color: Colors.white),
                        ),
                        subtitle: Text(
                          '${item.artist ?? 'Artiste inconnu'} · ${_itemStatusLabel(item.status)}',
                          style: const TextStyle(color: Colors.white54),
                        ),
                      ),
                    ),
                  ),
                if (_selectedItem != null) ...[
                  const SizedBox(height: 16),
                  const _SectionTitle(
                    icon: Icons.link_rounded,
                    title: 'Associer une piste existante',
                    subtitle: 'Recherche dans la bibliothèque HomeSpotify.',
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    key: const Key('admin-track-search-field'),
                    controller: _trackSearch,
                    onSubmitted: (_) => _searchTracks(),
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Titre et artiste',
                      suffixIcon: IconButton(
                        onPressed: _searching ? null : _searchTracks,
                        icon: _searching
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.search_rounded),
                      ),
                    ),
                  ),
                  if (!_searching && _trackResults.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 10),
                      child: Text(
                        'Lance la recherche pour voir les correspondances.',
                        style: TextStyle(color: Colors.white38, fontSize: 13),
                      ),
                    ),
                  for (final track in _trackResults)
                    Card(
                      color: adminCard,
                      margin: const EdgeInsets.only(top: 8),
                      child: ListTile(
                        leading: const Icon(
                          Icons.audio_file_rounded,
                          color: adminAccent,
                        ),
                        title: Text(
                          track.title,
                          style: const TextStyle(color: Colors.white),
                        ),
                        subtitle: Text(
                          '${track.artist} · ${track.album}',
                          style: const TextStyle(color: Colors.white54),
                        ),
                        trailing: FilledButton(
                          onPressed: _busy
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
                    ),
                ],
                const SizedBox(height: 24),
                const _SectionTitle(
                  icon: Icons.sticky_note_2_outlined,
                  title: 'Note privée',
                  subtitle: 'Visible uniquement par les administrateurs.',
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _note,
                  maxLines: 3,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    hintText: 'Ex. version précise à rechercher…',
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            decoration: const BoxDecoration(
              color: adminBackground,
              border: Border(top: BorderSide(color: Colors.white10)),
            ),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _busy
                    ? null
                    : () => _run(
                        () => widget.api.updateMusicRequest(
                          widget.item.id,
                          status: _status,
                          ownerNote: _note.text.trim(),
                        ),
                      ),
                icon: _busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_rounded),
                label: Text('Enregistrer · ${_statusLabel(_status)}'),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _SpotifyLinkCard extends StatelessWidget {
  const _SpotifyLinkCard({
    required this.link,
    required this.loading,
    required this.onResolve,
    required this.onOpen,
    required this.onCopy,
  });

  static const spotifyGreen = Color(0xFF1DB954);

  final AdminSpotifyLink? link;
  final bool loading;
  final VoidCallback onResolve;
  final VoidCallback onOpen;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: spotifyGreen.withValues(alpha: .09),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: spotifyGreen.withValues(alpha: .24)),
    ),
    child: link == null
        ? Row(
            children: [
              const CircleAvatar(
                backgroundColor: spotifyGreen,
                foregroundColor: Colors.black,
                child: Icon(Icons.play_arrow_rounded),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Spotify',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      'Trouve automatiquement cette demande.',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: Key('resolve-request-spotify-link'),
                onPressed: loading ? null : onResolve,
                style: FilledButton.styleFrom(
                  backgroundColor: spotifyGreen,
                  foregroundColor: Colors.black,
                ),
                child: loading
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.black,
                        ),
                      )
                    : const Text('Trouver'),
              ),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    link!.exact
                        ? Icons.verified_rounded
                        : Icons.manage_search_rounded,
                    color: spotifyGreen,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      link!.exact
                          ? 'Lien Spotify exact'
                          : 'Recherche Spotify préremplie',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Relancer la recherche',
                    onPressed: loading ? null : onResolve,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
              Text(
                '${link!.title} · ${link!.artist}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white60),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onCopy,
                      icon: const Icon(Icons.copy_rounded),
                      label: const Text('Copier'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: onOpen,
                      style: FilledButton.styleFrom(
                        backgroundColor: spotifyGreen,
                        foregroundColor: Colors.black,
                      ),
                      icon: const Icon(Icons.open_in_new_rounded),
                      label: const Text('Ouvrir'),
                    ),
                  ),
                ],
              ),
            ],
          ),
  );
}

class _RequestHero extends StatelessWidget {
  const _RequestHero({required this.item, required this.onOpenLink});

  final AdminMusicRequest item;
  final VoidCallback onOpenLink;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: adminCard,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Artwork(
              url: item.artworkUrl,
              icon: _typeIcon(item.itemType),
              size: 88,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    item.artist,
                    style: const TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                  if ((item.album ?? '').isNotEmpty)
                    Text(
                      item.album!,
                      style: const TextStyle(color: Colors.white38),
                    ),
                  const SizedBox(height: 10),
                  _StatusPill(
                    label: _statusLabel(item.status),
                    color: _statusColor(item.status),
                  ),
                ],
              ),
            ),
          ],
        ),
        const Divider(height: 28, color: Colors.white10),
        Row(
          children: [
            const Icon(
              Icons.person_outline_rounded,
              color: Colors.white38,
              size: 19,
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                'Demandé par ${item.requesterName} · ${formatDateTime(item.createdAt)}',
                style: const TextStyle(color: Colors.white54),
              ),
            ),
          ],
        ),
        if ((item.userNote ?? '').isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            '“${item.userNote}”',
            style: const TextStyle(color: Colors.white60),
          ),
        ],
        if (item.externalUrl != null) ...[
          const SizedBox(height: 10),
          TextButton.icon(
            key: const Key('open-request-external-url'),
            onPressed: onOpenLink,
            icon: const Icon(Icons.open_in_new_rounded),
            label: const Text('Ouvrir la source'),
          ),
        ],
      ],
    ),
  );
}

class _Artwork extends StatelessWidget {
  const _Artwork({required this.url, required this.icon, required this.size});

  final String? url;
  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    Widget fallback() => ColoredBox(
      color: const Color(0xFF252831),
      child: Center(
        child: Icon(icon, color: Colors.white38, size: size * .42),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * .16),
      child: SizedBox.square(
        dimension: size,
        child: url == null || url!.isEmpty
            ? fallback()
            : Image.network(
                url!,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => fallback(),
              ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .14),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      label,
      style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700),
    ),
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, color: adminAccent, size: 21),
      const SizedBox(width: 9),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: const TextStyle(color: Colors.white38, fontSize: 13),
            ),
          ],
        ),
      ),
    ],
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(
      padding: EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.inbox_rounded, size: 52, color: Colors.white24),
          SizedBox(height: 12),
          Text(
            'Aucune demande ici',
            style: TextStyle(color: Colors.white70, fontSize: 17),
          ),
          SizedBox(height: 4),
          Text(
            'Change de filtre ou reviens plus tard.',
            style: TextStyle(color: Colors.white38),
          ),
        ],
      ),
    ),
  );
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_rounded, color: adminError, size: 44),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Réessayer'),
          ),
        ],
      ),
    ),
  );
}
