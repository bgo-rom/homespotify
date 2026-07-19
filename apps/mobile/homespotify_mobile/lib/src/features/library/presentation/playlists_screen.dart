import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation.dart';
import '../../../core/logging/app_logger.dart';
import '../../player/presentation/widgets/mini_player.dart';
import 'library_playlists.dart';
import 'playlist_dialogs.dart';

const Color _bg = Color(0xFF0D0D10);
const Color _accent = Color(0xFF1DB954);

class PlaylistsScreen extends ConsumerStatefulWidget {
  const PlaylistsScreen({super.key});

  @override
  ConsumerState<PlaylistsScreen> createState() => _PlaylistsScreenState();
}

class _PlaylistsScreenState extends ConsumerState<PlaylistsScreen> {
  @override
  void initState() {
    super.initState();
    logLibrary('ouverture écran Playlists');
  }

  @override
  Widget build(BuildContext context) {
    final playlists = ref.watch(playlistsProvider);
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Playlists',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        actions: [
          IconButton(
            tooltip: 'Créer une playlist',
            onPressed: () => showCreatePlaylistDialog(context),
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
      body: playlists.when(
        loading: () =>
            const Center(child: CircularProgressIndicator(color: _accent)),
        error: (_, _) => const Center(
          child: Text(
            'Impossible de charger les playlists du compte.',
            style: TextStyle(color: Colors.white70),
          ),
        ),
        data: (items) => items.isEmpty
            ? const _EmptyPlaylists()
            : ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final playlist = items[index];
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 5,
                    ),
                    leading: const CircleAvatar(
                      backgroundColor: Color(0xFF282832),
                      foregroundColor: _accent,
                      child: Icon(Icons.queue_music_rounded),
                    ),
                    title: Text(
                      playlist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      '${playlist.trackCount} '
                      '${playlist.trackCount > 1 ? 'pistes' : 'piste'}',
                      style: const TextStyle(color: Colors.white54),
                    ),
                    trailing: const Icon(
                      Icons.chevron_right_rounded,
                      color: Colors.white38,
                    ),
                    onTap: () {
                      logUi(
                        'tap playlist: id=${playlist.id} '
                        'nom="${playlist.name}"',
                      );
                      openPlaylistDetail(context, playlist.id);
                    },
                  );
                },
              ),
      ),
      bottomNavigationBar: const MiniPlayer(),
    );
  }
}

class _EmptyPlaylists extends StatelessWidget {
  const _EmptyPlaylists();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.queue_music_rounded, size: 64, color: Colors.white24),
            SizedBox(height: 16),
            Text(
              'Aucune playlist',
              style: TextStyle(color: Colors.white70, fontSize: 16),
            ),
            SizedBox(height: 8),
            Text(
              'Crée une playlist pour organiser tes pistes.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
