import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/navigation.dart';
import '../../../core/network/authenticated_network_image.dart';
import '../../../core/theme/home_design.dart';
import '../../../core/widgets/home_ui_states.dart';
import '../../auth/application/auth_controller.dart';
import '../../catalog/data/catalog_api.dart';
import '../../library/presentation/track_removal.dart';
import '../../library/data/library_api.dart';
import '../../library/domain/track.dart';
import '../../library/presentation/library_filters.dart';
import '../../library/presentation/library_playback_controller.dart';
import '../../player/audio/homespotify_audio_handler.dart';
import '../../player/presentation/player_providers.dart';

class HomeDashboardScreen extends ConsumerStatefulWidget {
  const HomeDashboardScreen({super.key});

  @override
  ConsumerState<HomeDashboardScreen> createState() =>
      _HomeDashboardScreenState();
}

class _HomeDashboardScreenState extends ConsumerState<HomeDashboardScreen> {
  int? _loadingTrackId;

  Future<void> _playTrack(List<Track> tracks, Track track) async {
    if (_loadingTrackId == track.id) return;
    final index = tracks.indexWhere((candidate) => candidate.id == track.id);
    if (index < 0) return;
    // Lecture depuis le catalogue global : autorisée pour tout compte
    // authentifié, même si la piste n'est pas encore dans sa bibliothèque.
    setState(() => _loadingTrackId = track.id);
    try {
      await ref
          .read(libraryPlaybackControllerProvider)
          .playQueue(tracks: tracks, initialIndex: index);
    } catch (error) {
      if (!mounted) return;
      final message = error is AudioPlaybackException
          ? error.userMessage
          : 'La lecture n’a pas pu démarrer.';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted && _loadingTrackId == track.id) {
        setState(() => _loadingTrackId = null);
      }
    }
  }

  void _openLibrarySearch() {
    ref.read(librarySearchVisibleProvider.notifier).show();
    context.go('/library');
  }

  /// « Ajouter à ma bibliothèque » depuis le catalogue global — délègue au
  /// contrôleur CENTRAL (implémentation unique de l'action, partagée avec le
  /// menu du lecteur). N'interrompt jamais la lecture en cours.
  Future<void> _addToLibrary(CatalogEntry entry) =>
      addTrackToLibraryWithFeedback(
        context,
        ref,
        trackId: entry.track.id,
        title: entry.track.title,
      );

  @override
  Widget build(BuildContext context) {
    final displayName = ref.watch(
      authControllerProvider.select((state) => state.user?.displayName),
    );
    final library = ref.watch(libraryProvider);

    return Scaffold(
      backgroundColor: HomeDesign.background,
      body: SafeArea(
        child: RefreshIndicator(
          color: HomeDesign.accent,
          backgroundColor: HomeDesign.surface,
          onRefresh: () => ref.refresh(libraryProvider.future),
          child: CustomScrollView(
            key: const PageStorageKey<String>('home-dashboard-scroll'),
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: _CenteredContent(
                  child: HomeHeader(
                    displayName: displayName,
                    onSearch: _openLibrarySearch,
                    onProfile: () => context.go('/profile'),
                  ),
                ),
              ),
              const SliverToBoxAdapter(
                child: _CenteredContent(child: ContinueListeningCard()),
              ),
              SliverToBoxAdapter(
                child: _CenteredContent(
                  child: QuickAccessGrid(
                    onFavorites: () => openFavorites(context),
                    onPlaylists: () => openPlaylists(context),
                    onAlbums: () => openAlbums(context),
                    onArtists: () => openArtists(context),
                  ),
                ),
              ),
              ...library.when(
                loading: () => const <Widget>[
                  SliverToBoxAdapter(
                    child: _CenteredContent(
                      child: SizedBox(
                        height: 390,
                        child: HomeLoadingSkeleton(rows: 5),
                      ),
                    ),
                  ),
                ],
                error: (error, _) => <Widget>[
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
                data: (tracks) => tracks.isEmpty
                    ? const <Widget>[
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: HomeEmptyState(
                            icon: Icons.library_music_outlined,
                            title: 'Votre musique vous attend',
                            message:
                                'Les morceaux ajoutés à votre compte apparaîtront ici.',
                          ),
                        ),
                      ]
                    : <Widget>[
                        SliverToBoxAdapter(
                          child: _CenteredContent(
                            child: Builder(
                              builder: (context) {
                                // Catalogue GLOBAL anonymisé (jamais la
                                // bibliothèque personnelle du compte).
                                final entries =
                                    ref
                                        .watch(catalogRecentProvider)
                                        .asData
                                        ?.value ??
                                    const <CatalogEntry>[];
                                final catalogTracks = entries
                                    .map((entry) => entry.track)
                                    .toList(growable: false);
                                return RecentTracksSection(
                                  entries: entries,
                                  loadingTrackId: _loadingTrackId,
                                  onTrackTap: (track) =>
                                      _playTrack(catalogTracks, track),
                                  onAdd: _addToLibrary,
                                  onSeeAll: () => context.go('/library'),
                                );
                              },
                            ),
                          ),
                        ),
                        SliverToBoxAdapter(
                          child: _CenteredContent(
                            child: _LibrarySnapshot(tracks: tracks),
                          ),
                        ),
                      ],
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 32)),
            ],
          ),
        ),
      ),
    );
  }
}

class _CenteredContent extends StatelessWidget {
  const _CenteredContent({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: HomeDesign.maxContentWidth),
        child: _HomeReveal(child: child),
      ),
    );
  }
}

class _HomeReveal extends StatefulWidget {
  const _HomeReveal({required this.child});

  final Widget child;

  @override
  State<_HomeReveal> createState() => _HomeRevealState();
}

class _HomeRevealState extends State<_HomeReveal> {
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final duration = HomeDesign.animationDuration(
      context,
      HomeDesign.pageAnimation,
    );
    return AnimatedOpacity(
      opacity: _visible ? 1 : 0,
      duration: duration,
      curve: HomeDesign.animationCurve,
      child: AnimatedSlide(
        offset: _visible ? Offset.zero : const Offset(0, 0.025),
        duration: duration,
        curve: HomeDesign.animationCurve,
        child: widget.child,
      ),
    );
  }
}

class HomeHeader extends StatelessWidget {
  const HomeHeader({
    super.key,
    required this.displayName,
    required this.onSearch,
    required this.onProfile,
  });

  final String? displayName;
  final VoidCallback onSearch;
  final VoidCallback onProfile;

  String get _greeting {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Bonjour';
    if (hour < 18) return 'Bon après-midi';
    return 'Bonsoir';
  }

  @override
  Widget build(BuildContext context) {
    final name = displayName?.trim() ?? '';
    final hasName = name.isNotEmpty;
    final initial = hasName ? name.substring(0, 1).toUpperCase() : 'H';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _greeting,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  hasName ? name : 'Bienvenue sur HomeSpotify',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 27,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
              ],
            ),
          ),
          Semantics(
            button: true,
            label: 'Rechercher dans la bibliothèque',
            child: IconButton.filledTonal(
              key: const ValueKey('home-search-button'),
              tooltip: 'Rechercher',
              onPressed: onSearch,
              icon: const Icon(Icons.search_rounded),
            ),
          ),
          const SizedBox(width: HomeDesign.space8),
          Semantics(
            button: true,
            label: 'Ouvrir le profil',
            child: InkWell(
              onTap: onProfile,
              customBorder: const CircleBorder(),
              child: CircleAvatar(
                radius: 23,
                backgroundColor: HomeDesign.accent,
                foregroundColor: Colors.black,
                child: Text(
                  initial,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ContinueListeningCard extends ConsumerWidget {
  const ContinueListeningCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mediaItem = ref.watch(mediaItemProvider).asData?.value;
    if (mediaItem == null) return const SizedBox.shrink();
    final playback = ref.watch(playbackStateProvider).asData?.value;
    final playing = playback?.playing ?? false;
    final busy =
        playback?.processingState == AudioProcessingState.loading ||
        playback?.processingState == AudioProcessingState.buffering;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader(title: 'Reprendre l’écoute'),
          const SizedBox(height: HomeDesign.space12),
          Material(
            color: HomeDesign.surfaceRaised,
            borderRadius: BorderRadius.circular(HomeDesign.radiusLarge),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => openPlayer(context),
              child: AnimatedSwitcher(
                duration: HomeDesign.animationDuration(
                  context,
                  HomeDesign.stateAnimation,
                ),
                switchInCurve: HomeDesign.animationCurve,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0.03, 0),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: Padding(
                  key: ValueKey<String>('continue-${mediaItem.id}'),
                  padding: const EdgeInsets.all(HomeDesign.space16),
                  child: Row(
                    children: [
                      _DashboardArtwork(
                        trackId: mediaItem.id,
                        artUri: mediaItem.artUri,
                        size: 88,
                      ),
                      const SizedBox(width: HomeDesign.space16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              mediaItem.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                height: 1.15,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              mediaItem.artist ?? 'Artiste inconnu',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: HomeDesign.space12),
                            const _ContinueProgress(),
                          ],
                        ),
                      ),
                      const SizedBox(width: HomeDesign.space8),
                      IconButton.filled(
                        tooltip: playing ? 'Mettre en pause' : 'Reprendre',
                        onPressed: busy
                            ? null
                            : () {
                                final handler = ref.read(audioHandlerProvider);
                                playing ? handler.pause() : handler.play();
                              },
                        style: IconButton.styleFrom(
                          backgroundColor: HomeDesign.accent,
                          foregroundColor: Colors.black,
                          minimumSize: const Size(48, 48),
                        ),
                        icon: busy
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.2,
                                  color: Colors.black,
                                ),
                              )
                            : Icon(
                                playing
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ContinueProgress extends ConsumerWidget {
  const _ContinueProgress();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(positionDataProvider).asData?.value;
    final totalMs = data?.duration.inMilliseconds ?? 0;
    final progress = totalMs <= 0
        ? 0.0
        : ((data?.position.inMilliseconds ?? 0) / totalMs).clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: LinearProgressIndicator(
        minHeight: 3,
        value: progress,
        backgroundColor: Colors.white12,
        valueColor: const AlwaysStoppedAnimation<Color>(HomeDesign.accent),
      ),
    );
  }
}

class QuickAccessGrid extends StatelessWidget {
  const QuickAccessGrid({
    super.key,
    required this.onFavorites,
    required this.onPlaylists,
    required this.onAlbums,
    required this.onArtists,
  });

  final VoidCallback onFavorites;
  final VoidCallback onPlaylists;
  final VoidCallback onAlbums;
  final VoidCallback onArtists;

  @override
  Widget build(BuildContext context) {
    final items = [
      _QuickAccessItem('Favoris', Icons.favorite_rounded, onFavorites),
      _QuickAccessItem('Playlists', Icons.queue_music_rounded, onPlaylists),
      _QuickAccessItem('Albums', Icons.album_rounded, onAlbums),
      _QuickAccessItem('Artistes', Icons.groups_rounded, onArtists),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader(title: 'Accès rapides'),
          const SizedBox(height: HomeDesign.space12),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 720 ? 4 : 2;
              const gap = HomeDesign.space12;
              final width =
                  (constraints.maxWidth - (gap * (columns - 1))) / columns;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final item in items)
                    SizedBox(
                      width: width,
                      child: _QuickAccessCard(item: item),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _QuickAccessItem {
  const _QuickAccessItem(this.label, this.icon, this.onTap);
  final String label;
  final IconData icon;
  final VoidCallback onTap;
}

class _QuickAccessCard extends StatelessWidget {
  const _QuickAccessCard({required this.item});
  final _QuickAccessItem item;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: HomeDesign.surface,
      borderRadius: BorderRadius.circular(HomeDesign.radiusMedium),
      child: InkWell(
        onTap: item.onTap,
        borderRadius: BorderRadius.circular(HomeDesign.radiusMedium),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 68),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: HomeDesign.accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(item.icon, color: HomeDesign.accent, size: 21),
                ),
                const SizedBox(width: HomeDesign.space12),
                Expanded(
                  child: Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// « Ajouts récents » — alimentée par le CATALOGUE GLOBAL (tous comptes), pas
/// par la bibliothèque personnelle.
///
/// ANONYMAT : aucune carte n'affiche jamais qui a importé, demandé ou ajouté le
/// morceau (le backend ne transmet pas cette information). L'ordre vient déjà du
/// serveur (ajout au catalogue le plus récent d'abord).
class RecentTracksSection extends StatelessWidget {
  const RecentTracksSection({
    super.key,
    required this.entries,
    required this.loadingTrackId,
    required this.onTrackTap,
    required this.onAdd,
    required this.onSeeAll,
  });

  final List<CatalogEntry> entries;
  final int? loadingTrackId;
  final ValueChanged<Track> onTrackTap;
  final ValueChanged<CatalogEntry> onAdd;
  final VoidCallback onSeeAll;

  @override
  Widget build(BuildContext context) {
    final visible = entries.take(10).toList(growable: false);
    return Padding(
      padding: const EdgeInsets.only(bottom: HomeDesign.space24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _SectionHeader(
              title: 'Ajouts récents',
              actionLabel: 'Tout voir',
              onAction: onSeeAll,
            ),
          ),
          const SizedBox(height: HomeDesign.space12),
          SizedBox(
            // Hauteur = pochette (132) + titre + artiste + bouton « Ajouter ».
            // Marge volontaire pour les grandes polices Android.
            height: 206,
            child: ListView.separated(
              key: const PageStorageKey<String>('recent-tracks-scroll'),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: visible.length,
              separatorBuilder: (_, _) =>
                  const SizedBox(width: HomeDesign.space12),
              itemBuilder: (context, index) {
                final entry = visible[index];
                return _RecentTrackCard(
                  entry: entry,
                  loading: loadingTrackId == entry.track.id,
                  onTap: () => onTrackTap(entry.track),
                  onAdd: () => onAdd(entry),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _RecentTrackCard extends ConsumerWidget {
  const _RecentTrackCard({
    required this.entry,
    required this.loading,
    required this.onTap,
    required this.onAdd,
  });

  final CatalogEntry entry;
  final bool loading;
  final VoidCallback onTap;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = entry.track;
    final artUri = track.hasCover
        ? ref.read(libraryApiProvider).coverUri(track.id)
        : null;
    return SizedBox(
      width: 132,
      child: Semantics(
        button: true,
        label: 'Lire ${track.title} de ${track.artist}',
        child: InkWell(
          onTap: loading ? null : onTap,
          borderRadius: BorderRadius.circular(HomeDesign.radiusMedium),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  _DashboardArtwork(
                    trackId: '${track.id}',
                    artUri: artUri,
                    size: 132,
                  ),
                  if (loading)
                    const Positioned.fill(
                      child: ColoredBox(
                        color: Color(0x66000000),
                        child: Center(
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: HomeDesign.accent,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 7),
              Text(
                track.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                track.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white54, fontSize: 11.5),
              ),
              const SizedBox(height: 4),
              // Ajout explicite à SA bibliothèque. Aucune identité de
              // l'importateur n'est affichée — seulement l'état pour ce compte.
              _AddToLibraryButton(inMyLibrary: entry.inMyLibrary, onAdd: onAdd),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bouton « Ajouter » du catalogue global → devient « Dans votre bibliothèque »
/// une fois l'association `user_tracks` créée pour le compte courant.
class _AddToLibraryButton extends StatelessWidget {
  const _AddToLibraryButton({required this.inMyLibrary, required this.onAdd});

  final bool inMyLibrary;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    if (inMyLibrary) {
      return Semantics(
        label: 'Dans votre bibliothèque',
        child: const Row(
          children: [
            Icon(Icons.check_rounded, size: 14, color: HomeDesign.accent),
            SizedBox(width: 4),
            Expanded(
              child: Text(
                'Dans votre bibliothèque',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: HomeDesign.accent, fontSize: 11),
              ),
            ),
          ],
        ),
      );
    }
    return Semantics(
      button: true,
      label: 'Ajouter à ma bibliothèque',
      child: InkWell(
        onTap: onAdd,
        borderRadius: BorderRadius.circular(6),
        child: const Padding(
          padding: EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Icon(Icons.library_add_outlined, size: 14, color: Colors.white70),
              SizedBox(width: 4),
              Expanded(
                child: Text(
                  'Ajouter',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LibrarySnapshot extends StatelessWidget {
  const _LibrarySnapshot({required this.tracks});
  final List<Track> tracks;

  @override
  Widget build(BuildContext context) {
    final albums = tracks
        .map((track) => track.album.trim())
        .where((album) => album.isNotEmpty)
        .toSet()
        .length;
    final artists = tracks
        .map((track) => track.artist.trim().toLowerCase())
        .where((artist) => artist.isNotEmpty)
        .toSet()
        .length;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Material(
        color: HomeDesign.surface,
        borderRadius: BorderRadius.circular(HomeDesign.radiusMedium),
        child: Padding(
          padding: const EdgeInsets.all(HomeDesign.space16),
          child: Row(
            children: [
              const Icon(Icons.library_music_rounded, color: HomeDesign.accent),
              const SizedBox(width: HomeDesign.space12),
              Expanded(
                child: Text(
                  '${tracks.length} titres · $albums albums · $artists artistes',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.actionLabel, this.onAction});

  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (actionLabel != null && onAction != null)
          TextButton(onPressed: onAction, child: Text(actionLabel!)),
      ],
    );
  }
}

class _DashboardArtwork extends StatelessWidget {
  const _DashboardArtwork({
    required this.trackId,
    required this.artUri,
    required this.size,
  });

  final String trackId;
  final Uri? artUri;
  final double size;

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: HomeDesign.surfaceMuted,
      child: Icon(
        Icons.music_note_rounded,
        color: Colors.white24,
        size: size * 0.34,
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(HomeDesign.radiusMedium),
      child: SizedBox(
        width: size,
        height: size,
        child: artUri == null
            ? placeholder
            : AuthenticatedNetworkImage(
                artUri.toString(),
                key: ValueKey<String>('home-art-$trackId-$artUri'),
                fit: BoxFit.cover,
                cacheWidth: (size * 2).round(),
                cacheHeight: (size * 2).round(),
                filterQuality: FilterQuality.low,
                gaplessPlayback: true,
                loadingBuilder: (context, child, progress) =>
                    progress == null ? child : placeholder,
                errorBuilder: (_, _, _) => placeholder,
              ),
      ),
    );
  }
}
