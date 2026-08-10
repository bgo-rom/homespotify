import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shapes.dart';
import '../../../core/widgets/clay_header.dart';
import '../../../core/widgets/home_ui_states.dart';
import '../../../core/widgets/soft_surface.dart';
import '../../player/audio/homespotify_audio_handler.dart';
import '../../player/presentation/widgets/mini_player.dart';
import '../../offline/domain/offline_models.dart';
import '../../offline/presentation/offline_group_download_sheet.dart';
import '../data/library_api.dart';
import '../domain/track.dart';
import 'library_albums.dart';
import 'library_playback_controller.dart';
import 'track_actions_bottom_sheet.dart';
import 'widgets/album_tile.dart';

/// Détail d'un album : entête (pochette, méta, bouton Lire) + pistes.
///
/// Lancer une piste ou l'album ne navigue jamais vers le lecteur complet :
/// le mini-player se met à jour, l'utilisateur reste sur cet écran.
class AlbumDetailScreen extends ConsumerStatefulWidget {
  const AlbumDetailScreen({super.key, required this.albumKey});

  final String albumKey;

  @override
  ConsumerState<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends ConsumerState<AlbumDetailScreen> {
  int? _loadingTrackId;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final albums = ref.watch(albumsProvider);
    final album = _findAlbum(albums);

    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            ClayHeader(
              title: album?.title ?? 'Album',
              titleStyle: Theme.of(context).textTheme.headlineSmall,
              onBack: () => Navigator.of(context).maybePop(),
              actions: [
                if (album != null && album.tracks.isNotEmpty)
                  SoftCircle(
                    key: const ValueKey('album-download-all'),
                    size: 46,
                    onTap: () => showOfflineGroupDownloadSheet(
                      context,
                      type: OfflineGroupType.album,
                      sourceId: album.key,
                      title: album.title,
                      tracks: album.tracks,
                    ),
                    tooltip: 'Télécharger l’album',
                    semanticLabel: 'Télécharger l’album',
                    child: Icon(
                      Icons.download_for_offline_outlined,
                      size: 21,
                      color: colors.textPrimary,
                    ),
                  ),
              ],
            ),
            Expanded(
              child: album == null
                  ? _AlbumNotFound()
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 18),
                      children: [
                        _AlbumHeader(
                          album: album,
                          onPlay: _loadingTrackId == null
                              ? () => _playAlbum(context, album, 0)
                              : null,
                        ),
                        const SizedBox(height: 8),
                        for (var i = 0; i < album.tracks.length; i++)
                          _AlbumTrackTile(
                            index: i,
                            track: album.tracks[i],
                            isLoading: _loadingTrackId == album.tracks[i].id,
                            onTap: _loadingTrackId == album.tracks[i].id
                                ? null
                                : () => _playAlbum(context, album, i),
                            onLongPress: () => showTrackActionsBottomSheet(
                              context,
                              ref,
                              track: album.tracks[i],
                              origin: 'Album',
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: const MiniPlayer(),
    );
  }

  AlbumSummary? _findAlbum(List<AlbumSummary> albums) {
    for (final candidate in albums) {
      if (candidate.key == widget.albumKey) return candidate;
    }
    return null;
  }

  /// Lance la file de l'album à partir de [initialIndex]. Pas de navigation :
  /// précédent/suivant restent bornés aux pistes de l'album.
  Future<void> _playAlbum(
    BuildContext context,
    AlbumSummary album,
    int initialIndex,
  ) async {
    final track = album.tracks[initialIndex];
    if (_loadingTrackId == track.id) return;
    logUi(
      initialIndex == 0 && track.id == album.tracks.first.id
          ? 'tap Lire album "${album.title}" (${album.trackCount} pistes)'
          : 'tap piste album "${track.title}" (index=$initialIndex, '
                'album="${album.title}")',
    );
    setState(() => _loadingTrackId = track.id);
    try {
      await ref
          .read(libraryPlaybackControllerProvider)
          .playQueue(tracks: album.tracks, initialIndex: initialIndex);
    } catch (error) {
      if (_loadingTrackId == track.id && context.mounted) {
        final message = error is AudioPlaybackException
            ? error.userMessage
            : 'Erreur audio pendant la lecture.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Lecture impossible de « ${track.title} » : $message',
            ),
          ),
        );
      }
    } finally {
      if (mounted && _loadingTrackId == track.id) {
        setState(() => _loadingTrackId = null);
      }
    }
  }
}

class _AlbumHeader extends ConsumerWidget {
  const _AlbumHeader({required this.album, required this.onPlay});

  final AlbumSummary album;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final theme = Theme.of(context);
    final api = ref.read(libraryApiProvider);
    final meta = [
      album.artist,
      '${album.trackCount} ${album.trackCount > 1 ? 'pistes' : 'piste'}',
      formatAlbumDuration(album.totalDuration),
      if (album.dominantFormat != null) album.dominantFormat!,
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(AppLayout.gutter, 8, AppLayout.gutter, 0),
      child: Column(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: AppRadius.cardRadius,
              boxShadow: colors.clayShadow,
            ),
            child: SizedBox(
              width: 190,
              height: 190,
              child: AlbumCover(
                url: album.coverTrackId == null
                    ? null
                    : api.coverUri(album.coverTrackId!).toString(),
                borderRadius: AppRadius.card,
              ),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            album.title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.headlineSmall?.copyWith(
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            meta,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: colors.accent,
              foregroundColor: colors.onAccent,
              padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 13),
              shape: RoundedRectangleBorder(borderRadius: AppRadius.pillRadius),
            ),
            onPressed: onPlay,
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Lire'),
          ),
        ],
      ),
    );
  }
}

class _AlbumTrackTile extends StatelessWidget {
  const _AlbumTrackTile({
    required this.index,
    required this.track,
    required this.isLoading,
    required this.onTap,
    required this.onLongPress,
  });

  final int index;
  final Track track;
  final bool isLoading;
  final VoidCallback? onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    return ListTile(
      onTap: onTap,
      onLongPress: onLongPress,
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: AppLayout.gutter),
      leading: SizedBox(
        width: 24,
        child: Text(
          '${index + 1}',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.textTertiary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
      title: Text(
        track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleSmall?.copyWith(color: colors.textPrimary),
      ),
      subtitle: Text(
        isLoading ? 'Préparation de la lecture…' : track.artist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: isLoading ? colors.accent : colors.textSecondary,
        ),
      ),
      trailing: isLoading
          ? SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                color: colors.accent,
              ),
            )
          : Text(
              _formatTrackDuration(track.duration),
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.textTertiary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
    );
  }
}

class _AlbumNotFound extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return HomeEmptyState(
      icon: Icons.album_outlined,
      title: 'Album introuvable',
      message: 'Cet album n’est pas dans la bibliothèque chargée.',
      actionLabel: 'Retour',
      onAction: () => context.canPop() ? context.pop() : context.go('/'),
    );
  }
}

String _formatTrackDuration(Duration? d) {
  if (d == null) return '—';
  final minutes = d.inMinutes;
  final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
