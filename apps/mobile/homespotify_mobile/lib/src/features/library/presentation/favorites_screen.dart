import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shapes.dart';
import '../../../core/widgets/clay_header.dart';
import '../../../core/widgets/home_ui_states.dart';
import '../../player/audio/homespotify_audio_handler.dart';
import '../../player/presentation/widgets/mini_player.dart';
import '../data/library_api.dart';
import '../domain/track.dart';
import 'library_favorites.dart';
import 'library_playback_controller.dart';
import 'track_actions_bottom_sheet.dart';
import 'widgets/library_track_tile.dart';

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
    final colors = context.colors;
    final library = ref.watch(libraryProvider);
    final favorites = ref.watch(favoriteTrackIdsProvider);

    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            ClayHeader(
              title: 'Favoris',
              onBack: () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: library.when(
                loading: () => const HomeLoadingSkeleton(rows: 7),
                error: (error, _) => HomeErrorState(
                  message: error is LibraryApiException
                      ? error.message
                      : 'Impossible de charger la bibliothèque.',
                  onRetry: () => ref.invalidate(libraryProvider),
                ),
                data: (_) => favorites.when(
                  loading: () => const HomeLoadingSkeleton(rows: 7),
                  error: (_, _) => HomeErrorState(
                    message: 'Impossible de charger les favoris du compte.',
                    onRetry: () => ref.invalidate(favoriteTrackIdsProvider),
                  ),
                  data: (_) {
                    final tracks = ref.watch(favoriteTracksProvider);
                    if (tracks.isEmpty) {
                      return const HomeEmptyState(
                        icon: Icons.favorite_border_rounded,
                        title: 'Aucun favori',
                        message:
                            'Ajoute des pistes avec le bouton cœur pour les '
                            'retrouver ici.',
                      );
                    }
                    final api = ref.read(libraryApiProvider);
                    return ListView.builder(
                      padding: const EdgeInsets.fromLTRB(0, 6, 0, 18),
                      itemCount: tracks.length,
                      itemBuilder: (context, index) {
                        final track = tracks[index];
                        return Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              maxWidth: AppLayout.maxContentWidth,
                            ),
                            child: LibraryTrackTile(
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
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ),
          ],
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
