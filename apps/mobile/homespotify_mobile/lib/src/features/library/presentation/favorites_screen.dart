import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/network/authenticated_network_image.dart';
import '../../player/audio/homespotify_audio_handler.dart';
import '../../player/presentation/widgets/mini_player.dart';
import '../data/library_api.dart';
import '../domain/track.dart';
import 'library_favorites.dart';
import 'library_playback_controller.dart';
import 'track_actions_bottom_sheet.dart';
import 'widgets/track_favorite_button.dart';

const Color _bg = Color(0xFF0D0D10);
const Color _accent = Color(0xFF1DB954);

class FavoritesScreen extends ConsumerStatefulWidget {
  const FavoritesScreen({super.key});

  @override
  ConsumerState<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends ConsumerState<FavoritesScreen> {
  int? _loadingTrackId;

  @override
  void initState() {
    super.initState();
    logLibrary('ouverture écran Favoris');
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(libraryProvider);
    final favorites = ref.watch(favoriteTrackIdsProvider);

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Favoris',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: library.when(
        loading: () => const _LoadingState(),
        error: (error, _) => _ErrorState(
          message: error is LibraryApiException
              ? error.message
              : 'Impossible de charger la bibliothèque.',
        ),
        data: (_) => favorites.when(
          loading: () => const _LoadingState(),
          error: (_, _) => const _ErrorState(
            message: 'Impossible de charger les favoris du compte.',
          ),
          data: (_) {
            final tracks = ref.watch(favoriteTracksProvider);
            if (tracks.isEmpty) return const _EmptyFavorites();
            final api = ref.read(libraryApiProvider);
            return ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: tracks.length,
              itemBuilder: (context, index) {
                final track = tracks[index];
                return _FavoriteTrackTile(
                  track: track,
                  coverUrl: track.hasCover
                      ? api.coverUri(track.id).toString()
                      : null,
                  isLoading: _loadingTrackId == track.id,
                  onTap: _loadingTrackId == track.id
                      ? null
                      : () => _playFavorites(context, tracks, index),
                  onLongPress: () => showTrackActionsBottomSheet(
                    context,
                    ref,
                    track: track,
                    origin: 'Favoris',
                  ),
                );
              },
            );
          },
        ),
      ),
      bottomNavigationBar: const MiniPlayer(),
    );
  }

  Future<void> _playFavorites(
    BuildContext context,
    List<Track> tracks,
    int initialIndex,
  ) async {
    final track = tracks[initialIndex];
    if (_loadingTrackId == track.id) return;
    logUi(
      'lecture depuis Favoris: trackId=${track.id} '
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
}

class _FavoriteTrackTile extends StatelessWidget {
  const _FavoriteTrackTile({
    required this.track,
    required this.coverUrl,
    required this.isLoading,
    required this.onTap,
    required this.onLongPress,
  });

  final Track track;
  final String? coverUrl;
  final bool isLoading;
  final VoidCallback? onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final details = [
      track.artist,
      if (track.album.trim().isNotEmpty) track.album.trim(),
      if (track.duration != null) _formatDuration(track.duration!),
    ].join(' · ');
    return ListTile(
      onTap: onTap,
      onLongPress: onLongPress,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: _FavoriteArtwork(url: coverUrl),
      title: Text(
        track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        isLoading ? 'Préparation de la lecture...' : details,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: isLoading ? _accent : Colors.white54,
          fontSize: 12,
        ),
      ),
      trailing: isLoading
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                color: _accent,
              ),
            )
          : TrackFavoriteButton(
              trackId: track.id,
              visualDensity: VisualDensity.compact,
            ),
    );
  }
}

class _FavoriteArtwork extends StatelessWidget {
  const _FavoriteArtwork({this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(7),
      child: SizedBox(
        width: 52,
        height: 52,
        child: url == null
            ? const _ArtworkPlaceholder()
            : AuthenticatedNetworkImage(
                url!,
                fit: BoxFit.cover,
                cacheWidth: 104,
                cacheHeight: 104,
                filterQuality: FilterQuality.low,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => const _ArtworkPlaceholder(),
                loadingBuilder: (context, child, progress) =>
                    progress == null ? child : const _ArtworkPlaceholder(),
              ),
      ),
    );
  }
}

class _ArtworkPlaceholder extends StatelessWidget {
  const _ArtworkPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0xFF25252E),
      child: Icon(Icons.favorite_rounded, color: Colors.white24, size: 22),
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) {
    return const Center(child: CircularProgressIndicator(color: _accent));
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70, fontSize: 15),
        ),
      ),
    );
  }
}

class _EmptyFavorites extends StatelessWidget {
  const _EmptyFavorites();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.favorite_border_rounded,
              size: 64,
              color: Colors.white24,
            ),
            SizedBox(height: 16),
            Text(
              'Aucun favori',
              style: TextStyle(color: Colors.white70, fontSize: 16),
            ),
            SizedBox(height: 8),
            Text(
              'Ajoute des pistes avec le bouton cœur pour les retrouver ici.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatDuration(Duration duration) {
  final minutes = duration.inMinutes;
  final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
