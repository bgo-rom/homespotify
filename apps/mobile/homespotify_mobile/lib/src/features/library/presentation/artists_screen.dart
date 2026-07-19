import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation.dart';
import '../../../core/logging/app_logger.dart';
import '../../player/presentation/widgets/mini_player.dart';
import '../data/library_api.dart';
import 'library_artists.dart';
import 'widgets/artist_tile.dart';

const Color _bg = Color(0xFF0D0D10);
const Color _accent = Color(0xFF1DB954);

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
    final library = ref.watch(libraryProvider);
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Artistes',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: library.when(
        loading: () =>
            const Center(child: CircularProgressIndicator(color: _accent)),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              error is LibraryApiException
                  ? error.message
                  : 'Erreur inattendue.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 15),
            ),
          ),
        ),
        data: (_) {
          final artists = ref.watch(artistsProvider);
          if (artists.isEmpty) return const _EmptyArtists();
          final api = ref.read(libraryApiProvider);
          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: artists.length,
            itemBuilder: (context, index) {
              final artist = artists[index];
              return ArtistTile(
                artist: artist,
                coverUrl: artist.coverTrackId == null
                    ? null
                    : api.coverUri(artist.coverTrackId!).toString(),
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
          );
        },
      ),
      bottomNavigationBar: const MiniPlayer(),
    );
  }
}

class _EmptyArtists extends StatelessWidget {
  const _EmptyArtists();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.people_outline_rounded, size: 64, color: Colors.white24),
            SizedBox(height: 16),
            Text(
              'Aucun artiste',
              style: TextStyle(color: Colors.white70, fontSize: 16),
            ),
            SizedBox(height: 8),
            Text(
              'Les artistes apparaissent dès que la bibliothèque contient des pistes.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
