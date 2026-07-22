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
import '../application/offline_index.dart';
import '../application/offline_local_playback.dart';
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
        data: (data) => _buildBody(context, data),
      ),
    );
  }

  Widget _buildBody(BuildContext context, OfflineIndex index) {
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
          SliverToBoxAdapter(child: _Header(index: index)),
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
    ref.invalidate(offlineIndexProvider);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.index});

  final OfflineIndex index;

  @override
  Widget build(BuildContext context) {
    final count = index.availableCount;
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
              ],
            ),
          ),
        ],
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
