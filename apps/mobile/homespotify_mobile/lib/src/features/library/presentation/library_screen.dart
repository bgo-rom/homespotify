import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/theme/home_design.dart';
import '../../../core/widgets/home_ui_states.dart';
import '../../offline/application/offline_index.dart';
import '../../offline/application/offline_artwork_cache.dart';
import '../../player/audio/homespotify_audio_handler.dart';
import '../data/library_api.dart';
import '../domain/track.dart';
import 'library_filters.dart';
import 'library_playback_controller.dart';
import 'track_actions_bottom_sheet.dart';
import 'widgets/library_search_bar.dart';
import 'widgets/library_section_navigation.dart';
import 'widgets/library_sort_menu.dart';
import 'widgets/library_track_tile.dart';

/// Bibliothèque complète du compte courant. Les destinations principales et
/// le mini-player sont fournis par HomeShell, hors de cette arborescence.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  int? _loadingTrackId;
  bool _artworkSyncRunning = false;
  String? _artworkSyncSignature;

  void _toggleSearch() {
    ref.read(librarySearchVisibleProvider.notifier).toggle();
  }

  void _closeSearch() {
    ref.read(librarySearchQueryProvider.notifier).clear();
    ref.read(librarySearchVisibleProvider.notifier).hide();
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(libraryProvider);
    final mergedTracks = ref.watch(mergedLibraryTracksProvider);
    final searchVisible = ref.watch(librarySearchVisibleProvider);
    final trackCount = mergedTracks.isEmpty ? null : mergedTracks.length;
    final hasOfflineTracks = ref.watch(
      offlineAvailableTrackIdsProvider.select((ids) => ids.isNotEmpty),
    );
    final offlineIndex = ref.watch(offlineIndexProvider).asData?.value;
    if (library.hasValue && offlineIndex != null) {
      _scheduleArtworkSync(offlineIndex);
    }

    return Scaffold(
      backgroundColor: HomeDesign.background,
      body: RefreshIndicator(
        color: HomeDesign.accent,
        backgroundColor: HomeDesign.surface,
        onRefresh: () => ref.refresh(libraryProvider.future),
        child: CustomScrollView(
          key: const PageStorageKey<String>('library-tracks-scroll'),
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverAppBar(
              pinned: true,
              automaticallyImplyLeading: false,
              backgroundColor: HomeDesign.background,
              surfaceTintColor: HomeDesign.background,
              toolbarHeight: 72,
              titleSpacing: 16,
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Bibliothèque',
                    maxLines: 1,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 25,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.4,
                    ),
                  ),
                  if (trackCount != null)
                    Text(
                      '$trackCount ${trackCount > 1 ? 'morceaux' : 'morceau'}',
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                ],
              ),
              actions: [
                IconButton(
                  key: const ValueKey('library-downloads-button'),
                  tooltip: 'Téléchargements',
                  onPressed: () => context.push('/downloads'),
                  icon: const Icon(Icons.download_for_offline_outlined),
                ),
                IconButton(
                  key: const ValueKey('catalog-request-search-button'),
                  tooltip: 'Rechercher et demander une musique',
                  onPressed: () => context.push('/catalog-search'),
                  icon: const Icon(Icons.travel_explore_rounded),
                ),
                IconButton(
                  key: const ValueKey('library-search-button'),
                  tooltip: searchVisible ? 'Fermer la recherche' : 'Rechercher',
                  onPressed: searchVisible ? _closeSearch : _toggleSearch,
                  icon: AnimatedSwitcher(
                    duration: HomeDesign.animationDuration(
                      context,
                      HomeDesign.microAnimation,
                    ),
                    child: Icon(
                      searchVisible
                          ? Icons.close_rounded
                          : Icons.search_rounded,
                      key: ValueKey<bool>(searchVisible),
                    ),
                  ),
                ),
                const LibrarySortMenu(),
                const SizedBox(width: 4),
              ],
            ),
            const SliverToBoxAdapter(child: LibrarySectionNavigation()),
            const SliverToBoxAdapter(child: _DownloadedFilterChip()),
            SliverToBoxAdapter(
              child: AnimatedSize(
                duration: HomeDesign.animationDuration(
                  context,
                  HomeDesign.stateAnimation,
                ),
                curve: HomeDesign.animationCurve,
                alignment: Alignment.topCenter,
                child: searchVisible
                    ? LibrarySearchBar(autofocus: true, onClose: _closeSearch)
                    : const SizedBox.shrink(),
              ),
            ),
            ...library.when(
              loading: () => hasOfflineTracks
                  ? <Widget>[
                      _VisibleTrackList(
                        loadingTrackId: _loadingTrackId,
                        onPlay: _playQueue,
                      ),
                    ]
                  : <Widget>[
                      SliverToBoxAdapter(
                        child: Center(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: HomeDesign.maxContentWidth,
                            ),
                            child: SizedBox(
                              height: 520,
                              child: HomeLoadingSkeleton(rows: 7),
                            ),
                          ),
                        ),
                      ),
                    ],
              error: (error, _) => hasOfflineTracks
                  ? <Widget>[
                      _VisibleTrackList(
                        loadingTrackId: _loadingTrackId,
                        onPlay: _playQueue,
                      ),
                    ]
                  : <Widget>[
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: HomeErrorState(
                          message: error is LibraryApiException
                              ? error.message
                              : 'Une erreur inattendue est survenue.',
                          onRetry: () => ref.invalidate(libraryProvider),
                        ),
                      ),
                    ],
              data: (_) => mergedTracks.isEmpty
                  ? const <Widget>[
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: HomeEmptyState(
                          icon: Icons.library_music_outlined,
                          title: 'Aucune piste dans la bibliothèque',
                          message:
                              'Les fichiers FLAC et WAV attribués à votre compte apparaîtront ici.',
                        ),
                      ),
                    ]
                  : <Widget>[
                      _VisibleTrackList(
                        loadingTrackId: _loadingTrackId,
                        onPlay: _playQueue,
                      ),
                    ],
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 18)),
          ],
        ),
      ),
    );
  }

  void _scheduleArtworkSync(OfflineIndex index) {
    final missing =
        index.availableTrackIds
            .where((trackId) => index.coverUriForTrack(trackId) == null)
            .toList()
          ..sort();
    final signature = missing.join(',');
    if (_artworkSyncRunning ||
        missing.isEmpty ||
        signature == _artworkSyncSignature) {
      return;
    }
    _artworkSyncSignature = signature;
    _artworkSyncRunning = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final changed = await ref
          .read(offlineArtworkCacheProvider)
          .ensureMissingCovers(index);
      if (!mounted) return;
      _artworkSyncRunning = false;
      if (changed) {
        ref.invalidate(offlineIndexProvider);
      }
    });
  }

  Future<void> _playQueue(
    BuildContext context,
    List<Track> tracks,
    int initialIndex,
  ) async {
    final track = tracks[initialIndex];
    if (_loadingTrackId == track.id) return;
    logUi(
      'tap piste bibliothèque "${track.title}" '
      '(id=${track.id}, index=$initialIndex, file=${tracks.length} pistes)',
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

/// Filtre « Téléchargées » : visible seulement quand au moins une piste est
/// disponible hors ligne (aucun bruit pour un compte sans téléchargement).
class _DownloadedFilterChip extends ConsumerWidget {
  const _DownloadedFilterChip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloadedIds = ref.watch(offlineAvailableTrackIdsProvider);
    final selected = ref.watch(libraryDownloadedOnlyProvider);
    if (downloadedIds.isEmpty && !selected) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
      child: Align(
        alignment: Alignment.centerLeft,
        child: FilterChip(
          key: const ValueKey('library-filter-downloaded'),
          avatar: Icon(
            Icons.download_done_rounded,
            size: 16,
            color: selected ? HomeDesign.accent : Colors.white54,
          ),
          label: Text('Téléchargées (${downloadedIds.length})'),
          selected: selected,
          selectedColor: HomeDesign.accent.withValues(alpha: 0.22),
          onSelected: (_) =>
              ref.read(libraryDownloadedOnlyProvider.notifier).toggle(),
        ),
      ),
    );
  }
}

typedef _PlayTrackQueue =
    Future<void> Function(
      BuildContext context,
      List<Track> tracks,
      int initialIndex,
    );

class _VisibleTrackList extends ConsumerWidget {
  const _VisibleTrackList({required this.loadingTrackId, required this.onPlay});

  final int? loadingTrackId;
  final _PlayTrackQueue onPlay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = ref.watch(visibleTracksProvider);
    if (visible.isEmpty) {
      final query = ref.watch(librarySearchQueryProvider).trim();
      return SliverFillRemaining(
        hasScrollBody: false,
        child: HomeEmptyState(
          icon: Icons.search_off_rounded,
          title: 'Aucun résultat',
          message: query.isEmpty
              ? 'Aucun morceau ne correspond aux filtres actifs.'
              : 'Aucun résultat pour « $query ». Essayez un autre titre, artiste ou album.',
          actionLabel: query.isEmpty ? null : 'Effacer la recherche',
          onAction: query.isEmpty
              ? null
              : () => ref.read(librarySearchQueryProvider.notifier).clear(),
        ),
      );
    }
    final api = ref.read(libraryApiProvider);
    return SliverList.builder(
      itemCount: visible.length,
      itemBuilder: (context, index) {
        final track = visible[index];
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: HomeDesign.maxContentWidth,
            ),
            child: LibraryTrackTile(
              track: track,
              coverUrl: track.hasCover
                  ? api.coverUri(track.id).toString()
                  : null,
              isLoading: loadingTrackId == track.id,
              onTap: loadingTrackId == track.id
                  ? null
                  : () => onPlay(context, visible, index),
              onLongPress: () =>
                  showTrackActionsBottomSheet(context, ref, track: track),
            ),
          ),
        );
      },
    );
  }
}
