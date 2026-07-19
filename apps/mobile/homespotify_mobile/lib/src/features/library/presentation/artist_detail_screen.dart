import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/navigation.dart';
import '../../../core/logging/app_logger.dart';
import '../../player/audio/homespotify_audio_handler.dart';
import '../../player/presentation/widgets/mini_player.dart';
import '../data/library_api.dart';
import '../domain/track.dart';
import 'library_albums.dart';
import 'library_artists.dart';
import 'library_playback_controller.dart';
import 'track_actions_bottom_sheet.dart';
import 'widgets/album_tile.dart';
import 'widgets/artist_tile.dart';

const Color _bg = Color(0xFF0D0D10);
const Color _accent = Color(0xFF1DB954);

class ArtistDetailScreen extends ConsumerStatefulWidget {
  const ArtistDetailScreen({
    super.key,
    required this.artistKey,
    this.focusAlbums = false,
  });

  final String artistKey;
  final bool focusAlbums;

  @override
  ConsumerState<ArtistDetailScreen> createState() => _ArtistDetailScreenState();
}

class _ArtistDetailScreenState extends ConsumerState<ArtistDetailScreen> {
  final GlobalKey _albumsSectionKey = GlobalKey();
  int? _loadingTrackId;
  bool _albumsFocusScheduled = false;

  @override
  void initState() {
    super.initState();
    logLibrary(
      'ouverture détail artiste: clé="${widget.artistKey}" '
      'focusAlbums=${widget.focusAlbums}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(libraryProvider);
    final artists = ref.watch(artistsProvider);
    final artist = _findArtist(artists);

    if (artist != null && widget.focusAlbums && !_albumsFocusScheduled) {
      _albumsFocusScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final sectionContext = _albumsSectionKey.currentContext;
        if (!mounted || sectionContext == null) return;
        Scrollable.ensureVisible(
          sectionContext,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          alignment: 0.08,
        );
      });
    }

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          artist?.name ?? 'Artiste',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: library.when(
        loading: () =>
            const Center(child: CircularProgressIndicator(color: _accent)),
        error: (error, _) => _ArtistLoadError(
          message: error is LibraryApiException
              ? error.message
              : 'Erreur inattendue.',
        ),
        data: (_) => artist == null
            ? const _ArtistNotFound()
            : ListView(
                padding: const EdgeInsets.only(bottom: 16),
                children: [
                  _ArtistHeader(
                    artist: artist,
                    onPlay: _loadingTrackId == null
                        ? () => _playArtist(
                            context,
                            artist,
                            initialIndex: 0,
                            playAll: true,
                          )
                        : null,
                  ),
                  if (artist.albums.isNotEmpty)
                    _ArtistAlbumsSection(
                      key: _albumsSectionKey,
                      artist: artist,
                    ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 18, 20, 6),
                    child: Text(
                      'Titres',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  for (var index = 0; index < artist.tracks.length; index++)
                    _ArtistTrackTile(
                      index: index,
                      track: artist.tracks[index],
                      isLoading: _loadingTrackId == artist.tracks[index].id,
                      onTap: _loadingTrackId == artist.tracks[index].id
                          ? null
                          : () => _playArtist(
                              context,
                              artist,
                              initialIndex: index,
                              playAll: false,
                            ),
                      onLongPress: () => showTrackActionsBottomSheet(
                        context,
                        ref,
                        track: artist.tracks[index],
                        origin: 'Artiste',
                      ),
                    ),
                ],
              ),
      ),
      bottomNavigationBar: const MiniPlayer(),
    );
  }

  ArtistSummary? _findArtist(List<ArtistSummary> artists) {
    for (final candidate in artists) {
      if (candidate.key == widget.artistKey) return candidate;
    }
    return null;
  }

  Future<void> _playArtist(
    BuildContext context,
    ArtistSummary artist, {
    required int initialIndex,
    required bool playAll,
  }) async {
    final track = artist.tracks[initialIndex];
    if (_loadingTrackId == track.id) return;
    logUi(
      playAll
          ? 'tap Lire artiste "${artist.name}" (${artist.trackCount} pistes)'
          : 'tap piste artiste "${track.title}" (index=$initialIndex, '
                'artiste="${artist.name}")',
    );
    setState(() => _loadingTrackId = track.id);
    try {
      await ref
          .read(libraryPlaybackControllerProvider)
          .playQueue(tracks: artist.tracks, initialIndex: initialIndex);
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

class _ArtistHeader extends ConsumerWidget {
  const _ArtistHeader({required this.artist, required this.onPlay});

  final ArtistSummary artist;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(libraryApiProvider);
    final trackLabel = artist.trackCount > 1 ? 'pistes' : 'piste';
    final albumLabel = artist.albumCount > 1 ? 'albums' : 'album';
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
      child: Column(
        children: [
          SizedBox(
            width: 176,
            height: 176,
            child: ArtistArtwork(
              url: artist.coverTrackId == null
                  ? null
                  : api.coverUri(artist.coverTrackId!).toString(),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            artist.name,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${artist.trackCount} $trackLabel · '
            '${artist.albumCount} $albumLabel · '
            '${formatArtistDuration(artist.totalDuration)}',
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
              padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 12),
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

class _ArtistAlbumsSection extends ConsumerWidget {
  const _ArtistAlbumsSection({super.key, required this.artist});

  final ArtistSummary artist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(libraryApiProvider);
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              'Albums',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 154,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: artist.albums.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final album = artist.albums[index];
                return SizedBox(
                  width: 112,
                  child: InkWell(
                    key: ValueKey<String>('artist-album-${album.key}'),
                    borderRadius: BorderRadius.circular(8),
                    onTap: () {
                      logUi(
                        'tap album artiste "${album.title}" '
                        '(artiste="${artist.name}")',
                      );
                      openAlbumDetail(context, album.key);
                    },
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 112,
                          height: 112,
                          child: AlbumCover(
                            url: album.coverTrackId == null
                                ? null
                                : api.coverUri(album.coverTrackId!).toString(),
                            borderRadius: 8,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          album.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ArtistTrackTile extends StatelessWidget {
  const _ArtistTrackTile({
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
    final album = track.album.trim().isEmpty ? unknownAlbumTitle : track.album;
    return ListTile(
      onTap: onTap,
      onLongPress: onLongPress,
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      leading: SizedBox(
        width: 26,
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
        isLoading ? 'Préparation de la lecture...' : album,
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

class _ArtistLoadError extends StatelessWidget {
  const _ArtistLoadError({required this.message});

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

class _ArtistNotFound extends StatelessWidget {
  const _ArtistNotFound();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.person_off_outlined,
              size: 64,
              color: Colors.white24,
            ),
            const SizedBox(height: 16),
            const Text(
              'Artiste introuvable dans la bibliothèque chargée.',
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
                  context.canPop() ? context.pop() : context.go('/artists'),
              icon: const Icon(Icons.arrow_back_rounded),
              label: const Text('Retour'),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatTrackDuration(Duration? duration) {
  if (duration == null) return '—';
  final minutes = duration.inMinutes;
  final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
