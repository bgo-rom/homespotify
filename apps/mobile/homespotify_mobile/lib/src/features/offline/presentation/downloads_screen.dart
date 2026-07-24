import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/authenticated_network_image.dart';
import '../../../core/theme/home_design.dart';
import '../../../core/widgets/home_ui_states.dart';
import '../../auth/application/auth_controller.dart';
import '../../library/domain/track.dart';
import '../../library/presentation/widgets/current_track_indicator.dart';
import '../application/offline_artwork_cache.dart';
import '../application/offline_batch_download_manager.dart';
import '../application/offline_index.dart';
import '../application/offline_local_playback.dart';
import '../application/offline_storage_policy.dart';
import '../application/offline_track_downloader.dart';
import '../domain/offline_models.dart';
import 'offline_download_sheet.dart' show formatOfflineSize;

/// Écran Téléchargements : alimenté UNIQUEMENT par le manifeste SQLite local
/// (via [offlineIndexProvider]) — il fonctionne intégralement sans serveur.
/// Supprimer une copie locale ne touche jamais le serveur ni la bibliothèque.
class DownloadsScreen extends ConsumerStatefulWidget {
  const DownloadsScreen({super.key});

  @override
  ConsumerState<DownloadsScreen> createState() => _DownloadsScreenState();
}

enum _DownloadsFilter {
  all('Tous'),
  available('Disponibles'),
  inProgress('En cours'),
  broken('Interrompus / erreurs'),
  original('Original'),
  opus256('Opus 256'),
  opus128('Opus 128');

  const _DownloadsFilter(this.label);
  final String label;

  bool matches(OfflineIndexEntry entry) {
    final record = entry.record;
    return switch (this) {
      _DownloadsFilter.all => true,
      _DownloadsFilter.available => entry.available,
      _DownloadsFilter.inProgress =>
        record.status == OfflineDownloadStatus.waitingServer ||
            record.status == OfflineDownloadStatus.downloading ||
            record.status == OfflineDownloadStatus.verifying,
      _DownloadsFilter.broken =>
        record.status == OfflineDownloadStatus.failed ||
            record.status == OfflineDownloadStatus.cancelled ||
            record.status == OfflineDownloadStatus.stale ||
            (record.status == OfflineDownloadStatus.ready && !entry.available),
      _DownloadsFilter.original => record.profile == OfflineProfile.original,
      _DownloadsFilter.opus256 => record.profile == OfflineProfile.opus256,
      _DownloadsFilter.opus128 => record.profile == OfflineProfile.opus128,
    };
  }
}

class _DownloadsScreenState extends ConsumerState<DownloadsScreen> {
  _DownloadsFilter _filter = _DownloadsFilter.all;

  /// Progression vivante des reprises lancées depuis CET écran.
  final Map<int, OfflineDownloadProgress> _activeProgress = {};
  bool _artworkSyncRunning = false;
  String? _artworkSyncSignature;

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(offlineIndexProvider);
    final groups =
        ref.watch(offlineGroupsProvider).asData?.value ??
        const <OfflineDownloadGroup>[];
    final liveGroups = ref.watch(offlineBatchProgressProvider);
    return Scaffold(
      backgroundColor: HomeDesign.background,
      appBar: AppBar(title: const Text('Téléchargements')),
      body: index.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: HomeDesign.accent),
        ),
        error: (error, _) => HomeErrorState(
          message: 'Lecture du manifeste local impossible.',
          onRetry: () => ref.invalidate(offlineIndexProvider),
        ),
        data: (data) => _buildBody(context, data, groups, liveGroups),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    OfflineIndex index,
    List<OfflineDownloadGroup> groups,
    Map<String, OfflineBatchLiveProgress> liveGroups,
  ) {
    if (ref.read(authControllerProvider).status == AuthStatus.authenticated) {
      _scheduleArtworkSync(index);
    }
    final entries = index.entries
        .where(_filter.matches)
        .toList(growable: false);
    return RefreshIndicator(
      color: HomeDesign.accent,
      backgroundColor: HomeDesign.surface,
      onRefresh: () => ref.refresh(offlineIndexProvider.future),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: _Header(
              index: index,
              onSettings: _showStorageSettings,
              onCleanup: index.availableCount == 0
                  ? null
                  : () => _confirmLruCleanup(index),
            ),
          ),
          if (groups.isNotEmpty) ...[
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 14, 16, 4),
                child: Text(
                  'Albums et playlists',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            SliverList.builder(
              itemCount: groups.length,
              itemBuilder: (context, index) {
                final group = groups[index];
                return _DownloadGroupCard(
                  group: group,
                  liveProgress: liveGroups[group.id],
                  onPause: () => _pauseGroup(group),
                  onResume: () => _resumeGroup(group),
                  onCancel: () => _cancelGroup(group),
                  onDelete: () => _deleteGroup(group),
                );
              },
            ),
          ],
          SliverToBoxAdapter(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  for (final filter in _DownloadsFilter.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        key: ValueKey('downloads-filter-${filter.name}'),
                        label: Text(filter.label),
                        selected: _filter == filter,
                        selectedColor: HomeDesign.accent.withValues(
                          alpha: 0.22,
                        ),
                        onSelected: (_) => setState(() => _filter = filter),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (index.entries.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: HomeEmptyState(
                icon: Icons.download_for_offline_outlined,
                title: 'Aucun téléchargement',
                message:
                    'Depuis la bibliothèque, ouvre le menu d’une piste puis '
                    '« Télécharger » pour l’écouter sans connexion.',
              ),
            )
          else if (entries.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: HomeEmptyState(
                icon: Icons.filter_alt_off_rounded,
                title: 'Aucune piste pour ce filtre',
                message:
                    'Choisis un autre filtre pour voir tes copies locales.',
              ),
            )
          else
            SliverList.builder(
              itemCount: entries.length,
              itemBuilder: (context, i) => _DownloadTile(
                entry: entries[i],
                coverUrl: index
                    .coverUriForTrack(entries[i].record.trackId)
                    ?.toString(),
                liveProgress: _activeProgress[entries[i].record.trackId],
                onPlay: () => _play(entries[i], index),
                onRetry: () => _retry(entries[i].record),
                onDelete: () => _delete(entries[i].record),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

  Future<void> _pauseGroup(OfflineDownloadGroup group) async {
    await ref
        .read(offlineBatchDownloadManagerProvider)
        .pause(group.userId, group.id);
  }

  Future<void> _resumeGroup(OfflineDownloadGroup group) async {
    final manager = ref.read(offlineBatchDownloadManagerProvider);
    if (group.status == OfflineGroupStatus.partial ||
        group.status == OfflineGroupStatus.cancelled) {
      await manager.retryFailed(group.userId, group.id);
    } else {
      await manager.start(group.userId, group.id);
    }
  }

  Future<void> _cancelGroup(OfflineDownloadGroup group) async {
    await ref
        .read(offlineBatchDownloadManagerProvider)
        .cancel(group.userId, group.id);
  }

  Future<void> _deleteGroup(OfflineDownloadGroup group) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: HomeDesign.surface,
        title: const Text('Supprimer ces copies locales ?'),
        content: Text(
          'Les copies de « ${group.title} » avec le profil '
          '${offlineProfileShortLabel(group.profile)} seront supprimées de '
          'cet appareil. La bibliothèque serveur reste intacte.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          TextButton(
            key: const ValueKey('downloads-group-delete-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'Supprimer',
              style: TextStyle(color: Color(0xFFE57373)),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref
        .read(offlineBatchDownloadManagerProvider)
        .removeGroupCopies(group.userId, group.id);
  }

  Future<void> _showStorageSettings() async {
    final store = ref.read(offlineDownloadPreferencesStoreProvider);
    var preferences = await store.load();
    if (!mounted) return;
    final saved = await showDialog<OfflineDownloadPreferences>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: HomeDesign.surface,
          title: const Text('Téléchargements hors ligne'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Wi‑Fi uniquement'),
                subtitle: const Text(
                  'En partage de connexion ou 4G/5G, la file attendra.',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                value:
                    preferences.networkPolicy == OfflineNetworkPolicy.wifiOnly,
                onChanged: (wifiOnly) => setDialogState(() {
                  preferences = preferences.copyWith(
                    networkPolicy: wifiOnly
                        ? OfflineNetworkPolicy.wifiOnly
                        : OfflineNetworkPolicy.wifiAndCellular,
                  );
                }),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<int>(
                initialValue: preferences.maxStorageBytes,
                decoration: const InputDecoration(labelText: 'Limite du cache'),
                items: const [
                  DropdownMenuItem(
                    value: 2 * 1024 * 1024 * 1024,
                    child: Text('2 Go'),
                  ),
                  DropdownMenuItem(
                    value: 5 * 1024 * 1024 * 1024,
                    child: Text('5 Go'),
                  ),
                  DropdownMenuItem(
                    value: 10 * 1024 * 1024 * 1024,
                    child: Text('10 Go'),
                  ),
                  DropdownMenuItem(
                    value: 20 * 1024 * 1024 * 1024,
                    child: Text('20 Go'),
                  ),
                  DropdownMenuItem(value: 0, child: Text('Sans limite')),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setDialogState(() {
                    preferences = preferences.copyWith(maxStorageBytes: value);
                  });
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, preferences),
              child: const Text('Enregistrer'),
            ),
          ],
        ),
      ),
    );
    if (saved == null) return;
    await store.save(saved);
    final userId = ref.read(offlineUserIdProvider);
    if (userId != null) {
      await ref.read(offlineBatchDownloadManagerProvider).resumeForUser(userId);
    }
    if (mounted) setState(() {});
  }

  Future<void> _confirmLruCleanup(OfflineIndex index) async {
    final candidates = index.entries.where((entry) => entry.available).toList()
      ..sort((a, b) {
        final left =
            a.record.lastAccessedAt ??
            a.record.updatedAt ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final right =
            b.record.lastAccessedAt ??
            b.record.updatedAt ??
            DateTime.fromMillisecondsSinceEpoch(0);
        return left.compareTo(right);
      });
    if (candidates.isEmpty) return;
    const target = 1024 * 1024 * 1024;
    var selectedBytes = 0;
    final selected = <OfflineIndexEntry>[];
    for (final candidate in candidates) {
      selected.add(candidate);
      selectedBytes += candidate.record.sizeBytes ?? 0;
      if (selectedBytes >= target) break;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: HomeDesign.surface,
        title: const Text('Libérer de l’espace ?'),
        content: Text(
          '${selected.length} anciennes copies locales '
          '(${formatOfflineSize(selectedBytes, 'exact')}) seront supprimées. '
          'Aucun fichier du serveur ne sera modifié.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'Libérer',
              style: TextStyle(color: Color(0xFFE57373)),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final downloader = ref.read(offlineTrackDownloaderProvider);
    for (final entry in selected) {
      await downloader.removeLocal(
        entry.record.userId,
        entry.record.trackId,
        entry.record.profile,
      );
    }
    final userId = ref.read(offlineUserIdProvider);
    if (userId != null) {
      await ref
          .read(offlineBatchDownloadManagerProvider)
          .reconcileForUser(userId);
    }
    ref.invalidate(offlineIndexProvider);
  }

  void _scheduleArtworkSync(OfflineIndex index) {
    final missing =
        index.availableTrackIds
            .where((trackId) => index.coverUriForTrack(trackId) == null)
            .toList()
          ..sort();
    final signature = missing.join(',');
    if (_artworkSyncRunning ||
        missing.isEmpty ||
        signature == _artworkSyncSignature) {
      return;
    }
    _artworkSyncSignature = signature;
    _artworkSyncRunning = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final changed = await ref
          .read(offlineArtworkCacheProvider)
          .ensureMissingCovers(index);
      if (!mounted) return;
      _artworkSyncRunning = false;
      if (changed) {
        ref.invalidate(offlineIndexProvider);
      }
    });
  }

  Future<void> _play(OfflineIndexEntry entry, OfflineIndex index) async {
    try {
      await playLocalQueueFromTrack(ref, index, entry.record.trackId);
    } catch (_) {
      _snack('Lecture locale impossible : copie indisponible.');
      ref.invalidate(offlineIndexProvider);
    }
  }

  /// Reconstruit la piste minimale depuis le manifeste : la reprise ne dépend
  /// PAS de `GET /api/tracks` (mais exige le serveur pour le flux lui-même).
  Track _trackFromRecord(OfflineTrackRecord record) => Track(
    id: record.trackId,
    title: record.title ?? 'Piste ${record.trackId}',
    artist: record.artist ?? 'Artiste inconnu',
    album: record.album ?? '',
    hasCover: false,
    durationSeconds: record.durationSeconds,
    sizeBytes: record.sizeBytes,
    etag: record.sourceSha256,
    mimeType: record.profile == OfflineProfile.original ? record.codec : null,
    extension: record.profile == OfflineProfile.original
        ? record.container
        : '.ogg',
  );

  Future<void> _retry(OfflineTrackRecord record) async {
    final userId = record.userId;
    setState(() {
      _activeProgress[record.trackId] = const OfflineDownloadProgress(
        status: OfflineDownloadStatus.waitingServer,
        receivedBytes: 0,
      );
    });
    try {
      await ref
          .read(offlineTrackDownloaderProvider)
          .download(
            userId: userId,
            track: _trackFromRecord(record),
            profile: record.profile,
            onProgress: (progress) {
              if (mounted) {
                setState(() => _activeProgress[record.trackId] = progress);
              }
            },
          );
      _snack('Téléchargement terminé et vérifié.');
    } on DioException {
      _snack('Serveur injoignable : reprise impossible pour le moment.');
    } catch (error) {
      _snack('$error');
    } finally {
      if (mounted) {
        setState(() => _activeProgress.remove(record.trackId));
      }
      ref.invalidate(offlineIndexProvider);
    }
  }

  Future<void> _delete(OfflineTrackRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: HomeDesign.surface,
        title: const Text('Supprimer de cet appareil ?'),
        content: Text(
          '« ${record.title ?? 'Piste ${record.trackId}'} » '
          '(${offlineProfileShortLabel(record.profile)}) sera retirée du '
          'stockage local. La piste reste sur le serveur et dans ta '
          'bibliothèque.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          TextButton(
            key: const ValueKey('downloads-delete-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'Supprimer',
              style: TextStyle(color: Color(0xFFE57373)),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref
        .read(offlineTrackDownloaderProvider)
        .removeLocal(record.userId, record.trackId, record.profile);
    await ref
        .read(offlineBatchDownloadManagerProvider)
        .reconcileForUser(record.userId);
    ref.invalidate(offlineIndexProvider);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _Header extends ConsumerWidget {
  const _Header({
    required this.index,
    required this.onSettings,
    required this.onCleanup,
  });

  final OfflineIndex index;
  final VoidCallback onSettings;
  final VoidCallback? onCleanup;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = index.availableCount;
    final storage = ref.watch(offlineStoragePlatformProvider);
    final preferences = ref.watch(offlineDownloadPreferencesStoreProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Row(
        children: [
          const Icon(
            Icons.offline_pin_rounded,
            color: HomeDesign.accent,
            size: 28,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$count ${count > 1 ? 'pistes disponibles' : 'piste disponible'} hors ligne',
                  key: const ValueKey('downloads-header-count'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Espace occupé : ${formatOfflineSize(index.totalAvailableBytes, null)}',
                  key: const ValueKey('downloads-header-size'),
                  style: const TextStyle(color: Colors.white54, fontSize: 12.5),
                ),
                FutureBuilder<(int?, OfflineDownloadPreferences)>(
                  future: (() async =>
                      (await storage.freeBytes(), await preferences.load()))(),
                  builder: (context, snapshot) {
                    final data = snapshot.data;
                    if (data == null) return const SizedBox.shrink();
                    final free = data.$1;
                    final limit = data.$2.maxStorageBytes;
                    return Text(
                      [
                        if (free != null)
                          '${formatOfflineSize(free, 'exact')} libres',
                        limit <= 0
                            ? 'cache sans limite'
                            : 'limite ${formatOfflineSize(limit, 'exact')}',
                      ].join(' · '),
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11.5,
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Libérer de l’espace',
            onPressed: onCleanup,
            icon: const Icon(Icons.cleaning_services_outlined),
          ),
          IconButton(
            key: const ValueKey('downloads-storage-settings'),
            tooltip: 'Réseau et stockage',
            onPressed: onSettings,
            icon: const Icon(Icons.tune_rounded),
          ),
        ],
      ),
    );
  }
}

class _DownloadGroupCard extends StatelessWidget {
  const _DownloadGroupCard({
    required this.group,
    required this.liveProgress,
    required this.onPause,
    required this.onResume,
    required this.onCancel,
    required this.onDelete,
  });

  final OfflineDownloadGroup group;
  final OfflineBatchLiveProgress? liveProgress;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onCancel;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final running = group.status == OfflineGroupStatus.running;
    final resumable =
        group.status == OfflineGroupStatus.paused ||
        group.status == OfflineGroupStatus.waitingNetwork ||
        group.status == OfflineGroupStatus.partial ||
        group.status == OfflineGroupStatus.queued ||
        group.status == OfflineGroupStatus.cancelled;
    final status = switch (group.status) {
      OfflineGroupStatus.queued => 'En attente',
      OfflineGroupStatus.waitingNetwork => 'En attente du réseau autorisé',
      OfflineGroupStatus.running =>
        liveProgress == null
            ? 'Préparation'
            : 'Piste ${liveProgress!.trackId} · téléchargement',
      OfflineGroupStatus.paused => 'En pause',
      OfflineGroupStatus.completed => 'Terminé',
      OfflineGroupStatus.partial =>
        group.failedItems > 0
            ? '${group.failedItems} échec${group.failedItems > 1 ? 's' : ''}'
            : 'Copies manquantes',
      OfflineGroupStatus.cancelled => 'Annulé',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Material(
        color: HomeDesign.surface,
        borderRadius: BorderRadius.circular(HomeDesign.radiusMedium),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    group.type == OfflineGroupType.album
                        ? Icons.album_rounded
                        : Icons.queue_music_rounded,
                    color: HomeDesign.accent,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          group.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          '${offlineProfileShortLabel(group.profile)} · '
                          '${group.completedItems}/${group.totalItems} · $status',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (running)
                    IconButton(
                      tooltip: 'Mettre en pause',
                      onPressed: onPause,
                      icon: const Icon(Icons.pause_rounded),
                    ),
                  if (resumable)
                    IconButton(
                      tooltip: 'Reprendre',
                      onPressed: onResume,
                      icon: const Icon(Icons.play_arrow_rounded),
                    ),
                  if (running || group.status == OfflineGroupStatus.queued)
                    IconButton(
                      tooltip: 'Annuler',
                      onPressed: onCancel,
                      icon: const Icon(Icons.close_rounded),
                    ),
                  IconButton(
                    key: ValueKey('downloads-group-delete-${group.id}'),
                    tooltip: 'Supprimer les copies locales',
                    onPressed: running ? null : onDelete,
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              LinearProgressIndicator(
                value: liveProgress?.progress.ratio == null
                    ? group.ratio
                    : ((group.completedItems + liveProgress!.progress.ratio!) /
                              group.totalItems)
                          .clamp(0.0, 1.0),
                color: HomeDesign.accent,
                backgroundColor: Colors.white12,
                minHeight: 4,
              ),
              if (group.errorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    group.errorMessage!,
                    style: const TextStyle(
                      color: Color(0xFFE57373),
                      fontSize: 11.5,
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

String _statusLabel(OfflineIndexEntry entry) {
  if (entry.record.status == OfflineDownloadStatus.ready) {
    return entry.available ? 'Disponible' : 'Indisponible (fichier manquant)';
  }
  return switch (entry.record.status) {
    OfflineDownloadStatus.waitingServer => 'Préparation sur le serveur',
    OfflineDownloadStatus.downloading => 'Téléchargement',
    OfflineDownloadStatus.verifying => 'Vérification',
    OfflineDownloadStatus.cancelled => 'Interrompu',
    OfflineDownloadStatus.failed => 'Erreur',
    OfflineDownloadStatus.stale => 'Obsolète (source remplacée)',
    OfflineDownloadStatus.ready => 'Disponible',
  };
}

class _DownloadTile extends ConsumerWidget {
  const _DownloadTile({
    required this.entry,
    required this.coverUrl,
    required this.liveProgress,
    required this.onPlay,
    required this.onRetry,
    required this.onDelete,
  });

  final OfflineIndexEntry entry;
  final String? coverUrl;
  final OfflineDownloadProgress? liveProgress;
  final VoidCallback onPlay;
  final VoidCallback onRetry;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final record = entry.record;
    final playing = ref.watch(isTrackPlayingProvider('${record.trackId}'));
    final active = liveProgress != null;
    final canRetry =
        !active &&
        (record.status == OfflineDownloadStatus.failed ||
            record.status == OfflineDownloadStatus.cancelled ||
            record.status == OfflineDownloadStatus.stale ||
            (record.status == OfflineDownloadStatus.ready && !entry.available));
    final subtitleParts = [
      if (record.artist != null && record.artist!.isNotEmpty) record.artist!,
      if (record.album != null && record.album!.isNotEmpty) record.album!,
    ];
    final detail = [
      offlineProfileShortLabel(record.profile),
      if (record.sizeBytes != null)
        formatOfflineSize(record.sizeBytes, 'exact'),
      active ? _liveStatusLabel(liveProgress!) : _statusLabel(entry),
    ].join(' · ');
    final ratio = active
        ? liveProgress!.ratio
        : (record.status == OfflineDownloadStatus.cancelled &&
                  record.sizeBytes != null &&
                  record.sizeBytes! > 0
              ? record.receivedBytes / record.sizeBytes!
              : null);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Material(
        color: playing
            ? HomeDesign.accent.withValues(alpha: 0.09)
            : HomeDesign.surface,
        borderRadius: BorderRadius.circular(HomeDesign.radiusMedium),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  _DownloadArtwork(coverUrl: coverUrl, playing: playing),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          record.title ?? 'Piste ${record.trackId}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: playing ? HomeDesign.accent : Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (subtitleParts.isNotEmpty)
                          Text(
                            subtitleParts.join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 12.5,
                            ),
                          ),
                        Text(
                          detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (entry.available)
                    CurrentTrackIndicator(trackId: '${record.trackId}'),
                  if (entry.available)
                    IconButton(
                      key: ValueKey('downloads-play-${record.trackId}'),
                      tooltip: playing ? 'Relire depuis cette piste' : 'Lire',
                      onPressed: onPlay,
                      icon: const Icon(
                        Icons.play_circle_fill_rounded,
                        color: HomeDesign.accent,
                        size: 30,
                      ),
                    ),
                  if (canRetry)
                    IconButton(
                      key: ValueKey('downloads-retry-${record.trackId}'),
                      tooltip: 'Reprendre / réessayer',
                      onPressed: onRetry,
                      icon: const Icon(
                        Icons.refresh_rounded,
                        color: Colors.white70,
                      ),
                    ),
                  IconButton(
                    key: ValueKey('downloads-delete-${record.trackId}'),
                    tooltip: 'Supprimer de cet appareil',
                    onPressed: active ? null : onDelete,
                    icon: const Icon(
                      Icons.delete_outline_rounded,
                      color: Colors.white54,
                    ),
                  ),
                ],
              ),
              if (ratio != null || active) ...[
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: LinearProgressIndicator(
                    value: ratio,
                    color: HomeDesign.accent,
                    backgroundColor: Colors.white12,
                    minHeight: 3,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _liveStatusLabel(OfflineDownloadProgress progress) =>
      switch (progress.status) {
        OfflineDownloadStatus.waitingServer => 'Préparation sur le serveur',
        OfflineDownloadStatus.downloading => 'Téléchargement…',
        OfflineDownloadStatus.verifying => 'Vérification…',
        OfflineDownloadStatus.ready => 'Terminé',
        _ => 'En cours',
      };
}

class _DownloadArtwork extends StatelessWidget {
  const _DownloadArtwork({required this.coverUrl, required this.playing});

  final String? coverUrl;
  final bool playing;

  @override
  Widget build(BuildContext context) {
    final placeholder = const ColoredBox(
      color: HomeDesign.surfaceRaised,
      child: Icon(Icons.music_note_rounded, color: Colors.white24),
    );
    return AnimatedContainer(
      duration: HomeDesign.microAnimation,
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(HomeDesign.radiusSmall),
        border: Border.all(
          color: playing ? HomeDesign.accent : Colors.transparent,
          width: 2,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: coverUrl == null
          ? placeholder
          : AuthenticatedNetworkImage(
              coverUrl!,
              fit: BoxFit.cover,
              cacheWidth: 104,
              cacheHeight: 104,
              errorBuilder: (_, _, _) => placeholder,
            ),
    );
  }
}
