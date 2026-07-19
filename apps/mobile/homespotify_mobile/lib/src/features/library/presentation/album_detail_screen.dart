import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/logging/app_logger.dart';
import '../../player/audio/homespotify_audio_handler.dart';
import '../../player/presentation/widgets/mini_player.dart';
import '../data/library_api.dart';
import '../domain/track.dart';
import 'library_albums.dart';
import 'library_playback_controller.dart';
import 'track_actions_bottom_sheet.dart';
import 'widgets/album_tile.dart';

const Color _bg = Color(0xFF0D0D10);
const Color _accent = Color(0xFF1DB954);

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
    final albums = ref.watch(albumsProvider);
    final album = _findAlbum(albums);

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          album?.title ?? 'Album',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: album == null
          ? const _AlbumNotFound()
          : ListView(
              padding: const EdgeInsets.only(bottom: 16),
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
    final api = ref.read(libraryApiProvider);
    final meta = [
      album.artist,
      '${album.trackCount} ${album.trackCount > 1 ? 'pistes' : 'piste'}',
      formatAlbumDuration(album.totalDuration),
      if (album.dominantFormat != null) album.dominantFormat!,
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
      child: Column(
        children: [
          SizedBox(
            width: 180,
            height: 180,
            child: AlbumCover(
              url: album.coverTrackId == null
                  ? null
                  : api.coverUri(album.coverTrackId!).toString(),
              borderRadius: 14,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            album.title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            meta,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: _accent,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
            ),
            onPressed: onPlay,
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text(
              'Lire',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
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
    return ListTile(
      onTap: onTap,
      onLongPress: onLongPress,
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
      leading: SizedBox(
        width: 24,
        child: Text(
          '${index + 1}',
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white38,
            fontSize: 13,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ),
      title: Text(
        track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14.5,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Text(
        isLoading ? 'Préparation de la lecture...' : track.artist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: isLoading ? _accent : Colors.white54,
          fontSize: 12,
        ),
      ),
      trailing: isLoading
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                color: _accent,
              ),
            )
          : Text(
              _formatTrackDuration(track.duration),
              style: const TextStyle(
                color: Colors.white38,
                fontSize: 12,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
    );
  }
}

class _AlbumNotFound extends StatelessWidget {
  const _AlbumNotFound();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.album_outlined, size: 64, color: Colors.white24),
            const SizedBox(height: 16),
            const Text(
              'Album introuvable dans la bibliothèque chargée.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 15),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.black,
              ),
              onPressed: () =>
                  context.canPop() ? context.pop() : context.go('/'),
              icon: const Icon(Icons.arrow_back_rounded),
              label: const Text('Retour'),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatTrackDuration(Duration? d) {
  if (d == null) return '—';
  final minutes = d.inMinutes;
  final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
