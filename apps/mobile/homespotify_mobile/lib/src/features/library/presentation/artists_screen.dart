import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shapes.dart';
import '../../../core/widgets/clay_header.dart';
import '../../../core/widgets/home_ui_states.dart';
import '../../player/presentation/widgets/mini_player.dart';
import '../data/library_api.dart';
import 'library_artists.dart';
import 'widgets/artist_tile.dart';

class ArtistsScreen extends ConsumerStatefulWidget {
  const ArtistsScreen({super.key});

  @override
  ConsumerState<ArtistsScreen> createState() => _ArtistsScreenState();
}

class _ArtistsScreenState extends ConsumerState<ArtistsScreen> {
  @override
  void initState() {
    super.initState();
    logLibrary('ouverture écran Artistes');
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final library = ref.watch(libraryProvider);
    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            ClayHeader(
              title: 'Artistes',
              onBack: () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: library.when(
                loading: () => const HomeLoadingSkeleton(rows: 7),
                error: (error, _) => HomeErrorState(
                  message: error is LibraryApiException
                      ? error.message
                      : 'Erreur inattendue.',
                  onRetry: () => ref.invalidate(libraryProvider),
                ),
                data: (_) {
                  final artists = ref.watch(artistsProvider);
                  if (artists.isEmpty) {
                    return const HomeEmptyState(
                      icon: Icons.people_outline_rounded,
                      title: 'Aucun artiste',
                      message:
                          'Les artistes apparaissent dès que la bibliothèque '
                          'contient des pistes.',
                    );
                  }
                  final api = ref.read(libraryApiProvider);
                  return Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: AppLayout.maxContentWidth,
                      ),
                      child: ListView.builder(
                        padding: const EdgeInsets.fromLTRB(0, 6, 0, 18),
                        itemCount: artists.length,
                        itemBuilder: (context, index) {
                          final artist = artists[index];
                          return ArtistTile(
                            artist: artist,
                            coverUrl: artist.coverTrackId == null
                                ? null
                                : api
                                    .coverUri(artist.coverTrackId!)
                                    .toString(),
                            onTap: () {
                              final routeId = artistRouteId(artist.key);
                              logUi(
                                'tap artiste "${artist.name}" '
                                '(routeId="$routeId", ${artist.trackCount} pistes)',
                              );
                              openArtistDetail(context, artist.key);
                            },
                          );
                        },
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: const MiniPlayer(),
    );
  }
}
