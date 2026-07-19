import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation.dart';
import '../../../core/logging/app_logger.dart';
import '../../player/presentation/widgets/mini_player.dart';
import '../data/library_api.dart';
import 'library_albums.dart';
import 'widgets/album_tile.dart';

const Color _bg = Color(0xFF0D0D10);
const Color _accent = Color(0xFF1DB954);

/// Grille des albums dérivés des pistes chargées.
class AlbumsScreen extends ConsumerWidget {
  const AlbumsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(libraryProvider);

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Albums',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: library.when(
        loading: () =>
            const Center(child: CircularProgressIndicator(color: _accent)),
        error: (error, _) => Center(
          child: Text(
            error is LibraryApiException ? error.message : 'Erreur inattendue.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 15),
          ),
        ),
        data: (_) {
          final albums = ref.watch(albumsProvider);
          if (albums.isEmpty) return const _EmptyAlbums();
          final api = ref.read(libraryApiProvider);
          return GridView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
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
                    : api.coverUri(album.coverTrackId!).toString(),
                onTap: () {
                  logUi(
                    'tap album "${album.title}" (clé="${album.key}", '
                    '${album.trackCount} pistes)',
                  );
                  openAlbumDetail(context, album.key);
                },
              );
            },
          );
        },
      ),
      bottomNavigationBar: const MiniPlayer(),
    );
  }
}

class _EmptyAlbums extends StatelessWidget {
  const _EmptyAlbums();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.album_outlined, size: 64, color: Colors.white24),
            SizedBox(height: 16),
            Text(
              'Aucun album',
              style: TextStyle(color: Colors.white70, fontSize: 16),
            ),
            SizedBox(height: 8),
            Text(
              'Les albums apparaissent dès que la bibliothèque contient des pistes.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
