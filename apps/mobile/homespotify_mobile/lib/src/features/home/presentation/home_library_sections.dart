import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/navigation.dart';
import '../../../core/theme/home_design.dart';
import '../../remote_download/data/remote_download_api.dart';
import '../../remote_download/domain/remote_download_models.dart';
import '../../library/domain/local_playlist.dart';
import '../../library/domain/track.dart';
import '../../library/presentation/library_favorites.dart';
import '../../library/presentation/library_playlists.dart';
import '../application/home_sections.dart';
import 'home_section_widgets.dart';

/// Toutes les sections de l'accueil adossées à la bibliothèque du compte.
///
/// Chaque section disparaît complètement quand elle n'a rien à montrer : une
/// nouvelle installation affiche donc un accueil court plutôt qu'une pile de
/// titres vides.
class HomeLibrarySections extends ConsumerWidget {
  const HomeLibrarySections({
    super.key,
    required this.onPlayTrack,
    required this.loadingTrackId,
  });

  /// Lecture d'une piste dans le contexte de sa section (la file jouée est la
  /// section elle-même, pas la bibliothèque entière).
  final void Function(List<Track> queue, Track track) onPlayTrack;
  final int? loadingTrackId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recentlyPlayed = ref.watch(recentlyPlayedTracksProvider);
    final recentlyAdded = ref.watch(recentlyAddedTracksProvider);
    final recentAlbums = ref.watch(recentAlbumsProvider);
    final frequentArtists = ref.watch(frequentArtistsProvider);
    final favorites = ref.watch(favoriteTracksProvider);
    // Les playlists sont chargées de façon asynchrone : tant qu'elles ne
    // sont pas là, la section reste simplement absente.
    final playlists =
        ref.watch(playlistsProvider).asData?.value ?? const <LocalPlaylist>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const HomeInstallationsSection(),

        HomeCarousel(
          key: const ValueKey('home-recently-played'),
          title: 'Récemment écoutés',
          itemCount: recentlyPlayed.length,
          actionLabel: 'Historique',
          onAction: () => context.push('/listening-activity'),
          itemBuilder: (context, index) {
            final track = recentlyPlayed[index];
            return HomeTrackCard(
              track: track,
              loading: loadingTrackId == track.id,
              onTap: () => onPlayTrack(recentlyPlayed, track),
            );
          },
        ),

        HomeCarousel(
          key: const ValueKey('home-recently-added'),
          title: 'Récemment ajoutés',
          itemCount: recentlyAdded.length,
          actionLabel: 'Bibliothèque',
          onAction: () => context.go('/library'),
          itemBuilder: (context, index) {
            final track = recentlyAdded[index];
            return HomeTrackCard(
              track: track,
              loading: loadingTrackId == track.id,
              onTap: () => onPlayTrack(recentlyAdded, track),
            );
          },
        ),

        HomeCarousel(
          key: const ValueKey('home-recent-albums'),
          title: 'Albums récents',
          itemCount: recentAlbums.length,
          actionLabel: 'Tout voir',
          onAction: () => openAlbums(context),
          itemBuilder: (context, index) {
            final album = recentAlbums[index];
            return HomeMediaCard(
              title: album.title,
              subtitle: album.artist,
              coverTrackId: album.coverTrackId,
              onTap: () => openAlbumDetail(context, album.key),
            );
          },
        ),

        HomeCarousel(
          key: const ValueKey('home-frequent-artists'),
          title: 'Artistes fréquents',
          itemCount: frequentArtists.length,
          actionLabel: 'Tout voir',
          onAction: () => openArtists(context),
          itemBuilder: (context, index) {
            final artist = frequentArtists[index];
            return HomeMediaCard(
              title: artist.name,
              subtitle:
                  '${artist.tracks.length} '
                  '${artist.tracks.length > 1 ? 'titres' : 'titre'}',
              coverTrackId: artist.coverTrackId,
              rounded: true,
              onTap: () => openArtistDetail(context, artist.key),
            );
          },
        ),

        HomeCarousel(
          key: const ValueKey('home-favorites'),
          title: 'Favoris',
          itemCount: favorites.length > kHomeSectionLimit
              ? kHomeSectionLimit
              : favorites.length,
          actionLabel: 'Tout voir',
          onAction: () => openFavorites(context),
          itemBuilder: (context, index) {
            final track = favorites[index];
            return HomeTrackCard(
              track: track,
              loading: loadingTrackId == track.id,
              onTap: () => onPlayTrack(favorites, track),
            );
          },
        ),

        HomeCarousel(
          key: const ValueKey('home-playlists'),
          title: 'Playlists',
          itemCount: playlists.length > kHomeSectionLimit
              ? kHomeSectionLimit
              : playlists.length,
          actionLabel: 'Tout voir',
          onAction: () => openPlaylists(context),
          itemBuilder: (context, index) {
            final playlist = playlists[index];
            final coverTrack = ref
                .watch(playlistTracksProvider(playlist.id))
                .firstOrNull;
            return HomeMediaCard(
              title: playlist.name,
              subtitle:
                  '${playlist.trackIds.length} '
                  '${playlist.trackIds.length > 1 ? 'titres' : 'titre'}',
              coverTrackId: coverTrack?.hasCover == true
                  ? coverTrack!.id
                  : null,
              onTap: () => openPlaylistDetail(context, playlist.id),
            );
          },
        ),

        const HomeRecommendationsTeaser(),
      ],
    );
  }
}

/// Installations en cours, visibles seulement quand il y en a.
///
/// Il n'existe plus d'écran de file : le suivi détaillé vit dans la carte du
/// titre, sur l'écran de recherche. Cette section n'est qu'un rappel.
final _activeInstallsProvider = FutureProvider.autoDispose<List<RemoteDownload>>(
  (ref) async {
    try {
      final jobs = await ref
          .watch(remoteDownloadApiProvider)
          .listDownloads(limit: 20);
      return jobs.where((job) => job.status.isActive).toList(growable: false);
    } on RemoteDownloadException {
      // Moteur absent de ce serveur : l'accueil reste silencieux.
      return const [];
    }
  },
);

class HomeInstallationsSection extends ConsumerWidget {
  const HomeInstallationsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(_activeInstallsProvider).asData?.value ?? const [];
    if (active.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HomeSectionHeader(
          title: 'Installations en cours',
          actionLabel: 'Rechercher',
          onAction: () => context.push('/catalog-search'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: HomeDesign.space16),
          child: Column(
            key: const ValueKey('home-installations'),
            children: [
              for (final job in active.take(3))
                Container(
                  key: ValueKey('home-install-${job.id}'),
                  margin: const EdgeInsets.only(bottom: HomeDesign.space8),
                  padding: const EdgeInsets.all(HomeDesign.space12),
                  decoration: BoxDecoration(
                    color: HomeDesign.surface,
                    borderRadius: BorderRadius.circular(
                      HomeDesign.radiusMedium,
                    ),
                  ),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: HomeDesign.accent,
                        ),
                      ),
                      const SizedBox(width: HomeDesign.space12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              job.displayLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              job.status.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white38,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (job.progress > 0)
                        Text(
                          '${job.progress} %',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Entrée vers les recommandations.
///
/// L'accueil ne duplique PAS le deck de découverte : le moteur a son écran,
/// son cycle de préparation média et ses règles. On y renvoie.
class HomeRecommendationsTeaser extends StatelessWidget {
  const HomeRecommendationsTeaser({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HomeDesign.space16,
        HomeDesign.space24,
        HomeDesign.space16,
        0,
      ),
      child: InkWell(
        key: const ValueKey('home-recommendations'),
        onTap: () => openDiscover(context),
        borderRadius: BorderRadius.circular(HomeDesign.radiusMedium),
        child: Container(
          padding: const EdgeInsets.all(HomeDesign.space16),
          decoration: BoxDecoration(
            color: HomeDesign.surface,
            borderRadius: BorderRadius.circular(HomeDesign.radiusMedium),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.auto_awesome_rounded,
                color: HomeDesign.accent,
                size: 22,
              ),
              const SizedBox(width: HomeDesign.space12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Recommandations',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      'Des titres choisis à partir de vos écoutes',
                      style: TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: Colors.white38),
            ],
          ),
        ),
      ),
    );
  }
}
