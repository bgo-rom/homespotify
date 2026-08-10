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
import 'library_albums.dart';
import 'widgets/album_tile.dart';

/// Grille des albums dérivés des pistes chargées.
class AlbumsScreen extends ConsumerWidget {
  const AlbumsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final library = ref.watch(libraryProvider);

    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            ClayHeader(
              title: 'Albums',
              onBack: () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: library.when(
                loading: () => const HomeLoadingSkeleton(rows: 6),
                error: (error, _) => HomeErrorState(
                  message: error is LibraryApiException
                      ? error.message
                      : 'Erreur inattendue.',
                  onRetry: () => ref.invalidate(libraryProvider),
                ),
                data: (_) {
                  final albums = ref.watch(albumsProvider);
                  if (albums.isEmpty) {
                    return const HomeEmptyState(
                      icon: Icons.album_outlined,
                      title: 'Aucun album',
                      message:
                          'Les albums apparaissent dès que la bibliothèque '
                          'contient des pistes.',
                    );
                  }
                  final api = ref.read(libraryApiProvider);
                  return Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: AppLayout.maxContentWidth,
                      ),
                      child: GridView.builder(
                        padding: const EdgeInsets.fromLTRB(
                          AppLayout.gutter,
                          8,
                          AppLayout.gutter,
                          18,
                        ),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 220,
                          mainAxisSpacing: 16,
                          crossAxisSpacing: 16,
                          childAspectRatio: 0.72,
                        ),
                        itemCount: albums.length,
                        itemBuilder: (context, i) {
                          final album = albums[i];
                          return AlbumTile(
                            album: album,
                            coverUrl: album.coverTrackId == null
                                ? null
                                : api
                                    .coverUri(album.coverTrackId!)
                                    .toString(),
                            onTap: () {
                              logUi(
                                'tap album "${album.title}" (clé="${album.key}", '
                                '${album.trackCount} pistes)',
                              );
                              openAlbumDetail(context, album.key);
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
