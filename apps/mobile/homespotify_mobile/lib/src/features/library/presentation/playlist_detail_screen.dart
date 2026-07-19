import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/logging/app_logger.dart';
import '../../player/audio/homespotify_audio_handler.dart';
import '../../player/presentation/widgets/mini_player.dart';
import '../data/library_api.dart';
import '../domain/local_playlist.dart';
import '../domain/track.dart';
import 'library_playback_controller.dart';
import 'playlist_dialogs.dart';
import 'library_playlists.dart';
import 'track_actions_bottom_sheet.dart';
import 'widgets/current_track_indicator.dart';

const Color _bg = Color(0xFF0D0D10);
const Color _accent = Color(0xFF1DB954);

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
    final playlists = ref.watch(playlistsProvider);
    final library = ref.watch(libraryProvider);
    final playlist = ref.watch(playlistByIdProvider(widget.playlistId));
    final tracks = ref.watch(playlistTracksProvider(widget.playlistId));

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          playlist?.name ?? 'Playlist',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        actions: [
          if (playlist != null)
            IconButton(
              tooltip: 'Renommer la playlist',
              onPressed: () =>
                  showRenamePlaylistDialog(context, playlist: playlist),
              icon: const Icon(Icons.edit_outlined),
            ),
          if (playlist != null)
            IconButton(
              tooltip: 'Supprimer la playlist',
              onPressed: () => _deletePlaylist(playlist),
              icon: const Icon(Icons.delete_outline_rounded),
            ),
        ],
      ),
      body: playlists.when(
        loading: () => const _LoadingState(),
        error: (_, _) => const _ErrorState(
          message: 'Impossible de charger les playlists du compte.',
        ),
        data: (_) => library.when(
          loading: () => const _LoadingState(),
          error: (error, _) => _ErrorState(
            message: error is LibraryApiException
                ? error.message
                : 'Impossible de charger la bibliothèque.',
          ),
          data: (_) => playlist == null
              ? const _PlaylistNotFound()
              : _PlaylistContent(
                  playlist: playlist,
                  tracks: tracks,
                  loadingTrackId: _loadingTrackId,
                  onPlay: tracks.isEmpty || _loadingTrackId != null
                      ? null
                      : () => _playPlaylist(context, tracks, 0, playAll: true),
                  onTrackTap: (index) =>
                      _playPlaylist(context, tracks, index, playAll: false),
                  onTrackLongPress: (track) => showTrackActionsBottomSheet(
                    context,
                    ref,
                    track: track,
                    origin: 'Playlist',
                  ),
                  onRemove: (track) => _removeTrack(context, track),
                  onMove: (from, to) => _moveTrack(context, playlist, from, to),
                ),
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
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF23232B),
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
              backgroundColor: const Color(0xFFE57373),
              foregroundColor: Colors.black,
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
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 18),
          child: Column(
            children: [
              const CircleAvatar(
                radius: 48,
                backgroundColor: Color(0xFF282832),
                foregroundColor: _accent,
                child: Icon(Icons.queue_music_rounded, size: 46),
              ),
              const SizedBox(height: 14),
              Text(
                playlist.name,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${tracks.length} ${tracks.length > 1 ? 'pistes' : 'piste'}',
                style: const TextStyle(color: Colors.white54),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.black,
                ),
                onPressed: onPlay,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Lire'),
              ),
            ],
          ),
        ),
        if (tracks.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Text(
              'Cette playlist ne contient aucune piste.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54),
            ),
          )
        else
          for (var index = 0; index < tracks.length; index++)
            ListTile(
              onTap: loadingTrackId == tracks[index].id
                  ? null
                  : () => onTrackTap(index),
              onLongPress: () => onTrackLongPress(tracks[index]),
              contentPadding: const EdgeInsets.only(left: 20, right: 8),
              leading: SizedBox(
                width: 26,
                child: Text(
                  '${index + 1}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white38),
                ),
              ),
              title: Text(
                tracks[index].title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white),
              ),
              subtitle: Text(
                loadingTrackId == tracks[index].id
                    ? 'Préparation de la lecture...'
                    : tracks[index].artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: loadingTrackId == tracks[index].id
                      ? _accent
                      : Colors.white54,
                ),
              ),
              trailing: loadingTrackId == tracks[index].id
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          color: _accent,
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
                          color: Colors.white54,
                        ),
                        IconButton(
                          tooltip: 'Descendre',
                          onPressed: index == tracks.length - 1
                              ? null
                              : () => onMove(index, index + 1),
                          icon: const Icon(Icons.keyboard_arrow_down_rounded),
                          color: Colors.white54,
                        ),
                        IconButton(
                          tooltip: 'Retirer de la playlist',
                          onPressed: () => onRemove(tracks[index]),
                          icon: const Icon(Icons.remove_circle_outline_rounded),
                          color: Colors.white54,
                        ),
                      ],
                    ),
            ),
      ],
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) =>
      const Center(child: CircularProgressIndicator(color: _accent));
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white70),
      ),
    ),
  );
}

class _PlaylistNotFound extends StatelessWidget {
  const _PlaylistNotFound();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.playlist_remove_rounded,
              size: 64,
              color: Colors.white24,
            ),
            const SizedBox(height: 16),
            const Text(
              'Playlist introuvable.',
              style: TextStyle(color: Colors.white70, fontSize: 16),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.black,
              ),
              onPressed: () =>
                  context.canPop() ? context.pop() : context.go('/playlists'),
              icon: const Icon(Icons.arrow_back_rounded),
              label: const Text('Retour'),
            ),
          ],
        ),
      ),
    );
  }
}
