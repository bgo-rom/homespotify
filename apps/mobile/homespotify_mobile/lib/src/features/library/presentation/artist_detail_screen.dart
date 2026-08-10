import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/navigation.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shapes.dart';
import '../../../core/widgets/clay_header.dart';
import '../../../core/widgets/home_ui_states.dart';
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
    final colors = context.colors;
    final theme = Theme.of(context);
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
      backgroundColor: colors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            ClayHeader(
              title: artist?.name ?? 'Artiste',
              titleStyle: theme.textTheme.headlineSmall,
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
                data: (_) => artist == null
                    ? _ArtistNotFound()
                    : ListView(
                        padding: const EdgeInsets.only(bottom: 18),
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
                          Padding(
                            padding: const EdgeInsets.fromLTRB(
                              AppLayout.gutter, 18, AppLayout.gutter, 6),
                            child: Text(
                              'Titres',
                              style: theme.textTheme.titleLarge?.copyWith(
                                color: colors.textPrimary,
                              ),
                            ),
                          ),
                          for (var index = 0;
                              index < artist.tracks.length;
                              index++)
                            _ArtistTrackTile(
                              index: index,
                              track: artist.tracks[index],
                              isLoading:
                                  _loadingTrackId == artist.tracks[index].id,
                              onTap:
                                  _loadingTrackId == artist.tracks[index].id
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
    final colors = context.colors;
    final theme = Theme.of(context);
    final api = ref.read(libraryApiProvider);
    final trackLabel = artist.trackCount > 1 ? 'pistes' : 'piste';
    final albumLabel = artist.albumCount > 1 ? 'albums' : 'album';
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppLayout.gutter, 8, AppLayout.gutter, 4),
      child: Column(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: colors.clayShadow,
            ),
            child: SizedBox(
              width: 180,
              height: 180,
              child: ArtistArtwork(
                url: artist.coverTrackId == null
                    ? null
                    : api.coverUri(artist.coverTrackId!).toString(),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            artist.name,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.headlineSmall?.copyWith(
              color: colors.textPrimary,
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
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: colors.accent,
              foregroundColor: colors.onAccent,
              padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 13),
              shape: RoundedRectangleBorder(borderRadius: AppRadius.pillRadius),
            ),
            onPressed: onPlay,
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Lire'),
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
    final colors = context.colors;
    final theme = Theme.of(context);
    final api = ref.read(libraryApiProvider);
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppLayout.gutter),
            child: Text(
              'Albums',
              style: theme.textTheme.titleLarge?.copyWith(
                color: colors.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 160,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: AppLayout.gutter),
              itemCount: artist.albums.length,
              separatorBuilder: (_, _) => const SizedBox(width: 14),
              itemBuilder: (context, index) {
                final album = artist.albums[index];
                return SizedBox(
                  width: 118,
                  child: InkWell(
                    key: ValueKey<String>('artist-album-${album.key}'),
                    borderRadius: AppRadius.artworkRadius,
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
                        DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: AppRadius.artworkRadius,
                            boxShadow: colors.clayShadowSmall,
                          ),
                          child: SizedBox(
                            width: 118,
                            height: 118,
                            child: AlbumCover(
                              url: album.coverTrackId == null
                                  ? null
                                  : api
                                      .coverUri(album.coverTrackId!)
                                      .toString(),
                              borderRadius: AppRadius.artwork,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          album.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.textSecondary,
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
    final colors = context.colors;
    final theme = Theme.of(context);
    final album = track.album.trim().isEmpty ? unknownAlbumTitle : track.album;
    return ListTile(
      onTap: onTap,
      onLongPress: onLongPress,
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: AppLayout.gutter),
      leading: SizedBox(
        width: 26,
        child: Text(
          '${index + 1}',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.textTertiary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
      title: Text(
        track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleSmall?.copyWith(color: colors.textPrimary),
      ),
      subtitle: Text(
        isLoading ? 'Préparation de la lecture…' : album,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: isLoading ? colors.accent : colors.textSecondary,
        ),
      ),
      trailing: isLoading
          ? SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                color: colors.accent,
              ),
            )
          : Text(
              _formatTrackDuration(track.duration),
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.textTertiary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
    );
  }
}

class _ArtistNotFound extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return HomeEmptyState(
      icon: Icons.person_off_outlined,
      title: 'Artiste introuvable',
      message: 'Cet artiste n’est pas dans la bibliothèque chargée.',
      actionLabel: 'Retour',
      onAction: () => context.canPop() ? context.pop() : context.go('/artists'),
    );
  }
}

String _formatTrackDuration(Duration? duration) {
  if (duration == null) return '—';
  final minutes = duration.inMinutes;
  final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
