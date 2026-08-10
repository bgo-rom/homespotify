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
import '../domain/local_playlist.dart';
import '../domain/track.dart';
import 'library_playback_controller.dart';
import 'playlist_dialogs.dart';
import 'library_playlists.dart';
import 'track_actions_bottom_sheet.dart';
import 'widgets/current_track_indicator.dart';

class PlaylistDetailScreen extends ConsumerStatefulWidget {
  const PlaylistDetailScreen({super.key, required this.playlistId});

  final String playlistId;

  @override
  ConsumerState<PlaylistDetailScreen> createState() =>
      _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends ConsumerState<PlaylistDetailScreen> {
  int? _loadingTrackId;

  @override
  void initState() {
    super.initState();
    logLibrary('ouverture détail playlist: id=${widget.playlistId}');
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final playlists = ref.watch(playlistsProvider);
    final library = ref.watch(libraryProvider);
    final playlist = ref.watch(playlistByIdProvider(widget.playlistId));
    final tracks = ref.watch(playlistTracksProvider(widget.playlistId));

    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            ClayHeader(
              title: playlist?.name ?? 'Playlist',
              titleStyle: Theme.of(context).textTheme.headlineSmall,
              onBack: () => Navigator.of(context).maybePop(),
              actions: [
                if (playlist != null && tracks.isNotEmpty)
                  _HeaderAction(
                    keyValue: 'playlist-download-all',
                    icon: Icons.download_for_offline_outlined,
                    tooltip: 'Télécharger la playlist',
                    onTap: () => showOfflineGroupDownloadSheet(
                      context,
                      type: OfflineGroupType.playlist,
                      sourceId: playlist.id,
                      title: playlist.name,
                      tracks: tracks,
                    ),
                  ),
                if (playlist != null)
                  _HeaderAction(
                    icon: Icons.edit_outlined,
                    tooltip: 'Renommer la playlist',
                    onTap: () =>
                        showRenamePlaylistDialog(context, playlist: playlist),
                  ),
                if (playlist != null)
                  _HeaderAction(
                    icon: Icons.delete_outline_rounded,
                    tooltip: 'Supprimer la playlist',
                    onTap: () => _deletePlaylist(playlist),
                  ),
              ],
            ),
            Expanded(
              child: playlists.when(
                loading: () => const HomeLoadingSkeleton(rows: 7),
                error: (_, _) => HomeErrorState(
                  message: 'Impossible de charger les playlists du compte.',
                  onRetry: () => ref.invalidate(playlistsProvider),
                ),
                data: (_) => library.when(
                  loading: () => const HomeLoadingSkeleton(rows: 7),
                  error: (error, _) => HomeErrorState(
                    message: error is LibraryApiException
                        ? error.message
                        : 'Impossible de charger la bibliothèque.',
                    onRetry: () => ref.invalidate(libraryProvider),
                  ),
                  data: (_) => playlist == null
                      ? _PlaylistNotFound()
                      : _PlaylistContent(
                          playlist: playlist,
                          tracks: tracks,
                          loadingTrackId: _loadingTrackId,
                          onPlay: tracks.isEmpty || _loadingTrackId != null
                              ? null
                              : () => _playPlaylist(
                                  context, tracks, 0, playAll: true),
                          onTrackTap: (index) => _playPlaylist(
                              context, tracks, index, playAll: false),
                          onTrackLongPress: (track) =>
                              showTrackActionsBottomSheet(
                            context,
                            ref,
                            track: track,
                            origin: 'Playlist',
                          ),
                          onRemove: (track) => _removeTrack(context, track),
                          onMove: (from, to) =>
                              _moveTrack(context, playlist, from, to),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: const MiniPlayer(),
    );
  }

  Future<void> _playPlaylist(
    BuildContext context,
    List<Track> tracks,
    int initialIndex, {
    required bool playAll,
  }) async {
    final track = tracks[initialIndex];
    if (_loadingTrackId == track.id) return;
    logUi(
      '${playAll ? 'lecture playlist' : 'tap piste playlist'}: '
      'playlistId=${widget.playlistId} trackId=${track.id} '
      'index=$initialIndex file=${tracks.length}',
    );
    setState(() => _loadingTrackId = track.id);
    try {
      await ref
          .read(libraryPlaybackControllerProvider)
          .playQueue(tracks: tracks, initialIndex: initialIndex);
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

  Future<void> _removeTrack(BuildContext context, Track track) async {
    try {
      await ref
          .read(playlistsProvider.notifier)
          .removeTrack(widget.playlistId, track.id);
    } catch (error, stackTrace) {
      logError(
        'échec retrait piste depuis détail playlist',
        error: error,
        stackTrace: stackTrace,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Impossible de retirer cette piste.')),
        );
      }
    }
  }

  Future<void> _moveTrack(
    BuildContext context,
    LocalPlaylist playlist,
    int from,
    int to,
  ) async {
    if (to < 0 || to >= playlist.trackIds.length || from == to) return;
    final reordered = List<int>.of(playlist.trackIds);
    final trackId = reordered.removeAt(from);
    reordered.insert(to, trackId);
    try {
      await ref
          .read(playlistsProvider.notifier)
          .reorder(playlist.id, reordered);
    } catch (error, stackTrace) {
      logError(
        'échec réordonnancement playlist',
        error: error,
        stackTrace: stackTrace,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Impossible de réordonner la playlist.'),
          ),
        );
      }
    }
  }

  Future<void> _deletePlaylist(LocalPlaylist playlist) async {
    final colors = context.colors;
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: colors.surfaceRaised,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.cardRadius),
        title: const Text('Supprimer cette playlist ?'),
        content: Text(
          '« ${playlist.name} » sera supprimée de cet appareil. '
          'Les fichiers audio ne seront pas modifiés.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: colors.danger,
              foregroundColor: colors.onAccent,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;

    logUi('confirmation suppression playlist: id=${playlist.id}');
    try {
      final deleted = await ref
          .read(playlistsProvider.notifier)
          .delete(playlist.id);
      if (!mounted || !deleted) return;
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/playlists');
      }
    } catch (error, stackTrace) {
      logError(
        'échec suppression playlist depuis détail',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Impossible de supprimer la playlist.')),
        );
      }
    }
  }
}

/// Bouton d'action sculpté d'en-tête (réutilise [SoftCircle], taille compacte).
class _HeaderAction extends StatelessWidget {
  const _HeaderAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.keyValue,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final String? keyValue;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SoftCircle(
      key: keyValue == null ? null : ValueKey<String>(keyValue!),
      size: 44,
      onTap: onTap,
      tooltip: tooltip,
      semanticLabel: tooltip,
      child: Icon(icon, size: 20, color: colors.textPrimary),
    );
  }
}

class _PlaylistContent extends StatelessWidget {
  const _PlaylistContent({
    required this.playlist,
    required this.tracks,
    required this.loadingTrackId,
    required this.onPlay,
    required this.onTrackTap,
    required this.onTrackLongPress,
    required this.onRemove,
    required this.onMove,
  });

  final LocalPlaylist playlist;
  final List<Track> tracks;
  final int? loadingTrackId;
  final VoidCallback? onPlay;
  final ValueChanged<int> onTrackTap;
  final ValueChanged<Track> onTrackLongPress;
  final ValueChanged<Track> onRemove;
  final void Function(int from, int to) onMove;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.only(bottom: 18),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(AppLayout.gutter, 12, AppLayout.gutter, 18),
          child: Column(
            children: [
              Container(
                width: 108,
                height: 108,
                decoration: BoxDecoration(
                  color: colors.clayBlue,
                  borderRadius: AppRadius.cardRadius,
                  boxShadow: colors.clayShadow,
                ),
                child: Icon(
                  Icons.queue_music_rounded,
                  size: 50,
                  color: colors.clayBlueInk,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                playlist.name,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${tracks.length} ${tracks.length > 1 ? 'pistes' : 'piste'}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: colors.accent,
                  foregroundColor: colors.onAccent,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 30, vertical: 13),
                  shape:
                      RoundedRectangleBorder(borderRadius: AppRadius.pillRadius),
                ),
                onPressed: onPlay,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Lire'),
              ),
            ],
          ),
        ),
        if (tracks.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              'Cette playlist ne contient aucune piste.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.textSecondary,
              ),
            ),
          )
        else
          for (var index = 0; index < tracks.length; index++)
            ListTile(
              onTap: loadingTrackId == tracks[index].id
                  ? null
                  : () => onTrackTap(index),
              onLongPress: () => onTrackLongPress(tracks[index]),
              contentPadding: const EdgeInsets.only(left: AppLayout.gutter, right: 8),
              leading: SizedBox(
                width: 26,
                child: Text(
                  '${index + 1}',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.textTertiary,
                  ),
                ),
              ),
              title: Text(
                tracks[index].title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: colors.textPrimary,
                ),
              ),
              subtitle: Text(
                loadingTrackId == tracks[index].id
                    ? 'Préparation de la lecture…'
                    : tracks[index].artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: loadingTrackId == tracks[index].id
                      ? colors.accent
                      : colors.textSecondary,
                ),
              ),
              trailing: loadingTrackId == tracks[index].id
                  ? Padding(
                      padding: const EdgeInsets.all(12),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          color: colors.accent,
                        ),
                      ),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CurrentTrackIndicator(trackId: '${tracks[index].id}'),
                        IconButton(
                          tooltip: 'Monter',
                          onPressed: index == 0
                              ? null
                              : () => onMove(index, index - 1),
                          icon: const Icon(Icons.keyboard_arrow_up_rounded),
                          color: colors.textSecondary,
                        ),
                        IconButton(
                          tooltip: 'Descendre',
                          onPressed: index == tracks.length - 1
                              ? null
                              : () => onMove(index, index + 1),
                          icon: const Icon(Icons.keyboard_arrow_down_rounded),
                          color: colors.textSecondary,
                        ),
                        IconButton(
                          tooltip: 'Retirer de la playlist',
                          onPressed: () => onRemove(tracks[index]),
                          icon:
                              const Icon(Icons.remove_circle_outline_rounded),
                          color: colors.textSecondary,
                        ),
                      ],
                    ),
            ),
      ],
    );
  }
}

class _PlaylistNotFound extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return HomeEmptyState(
      icon: Icons.playlist_remove_rounded,
      title: 'Playlist introuvable',
      message: 'Cette playlist n’existe plus sur cet appareil.',
      actionLabel: 'Retour',
      onAction: () =>
          context.canPop() ? context.pop() : context.go('/playlists'),
    );
  }
}
