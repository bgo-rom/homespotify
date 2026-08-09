import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/navigation.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shapes.dart';
import '../../../core/theme/home_design.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../core/widgets/artwork_thumb.dart';
import '../../../core/widgets/home_ui_states.dart';
import '../../../core/widgets/section_header.dart';
import '../../../core/widgets/soft_surface.dart';
import '../../auth/application/auth_controller.dart';
import '../../catalog/data/catalog_api.dart';
import '../../library/presentation/track_removal.dart';
import '../../library/data/library_api.dart';
import '../../library/domain/track.dart';
import '../../library/presentation/library_filters.dart';
import '../../library/presentation/library_playback_controller.dart';
import '../../player/audio/homespotify_audio_handler.dart';
import '../../player/presentation/player_providers.dart';
import '../application/home_sections.dart';
import 'home_library_sections.dart';

/// Accueil — « Direction 33, Clay Tactile Premium ».
///
/// Premier écran migré : il fait référence pour tous les suivants. Aucune
/// couleur n'y est écrite en dur, tout vient de `context.colors`.
class HomeDashboardScreen extends ConsumerStatefulWidget {
  const HomeDashboardScreen({super.key});

  @override
  ConsumerState<HomeDashboardScreen> createState() =>
      _HomeDashboardScreenState();
}

class _HomeDashboardScreenState extends ConsumerState<HomeDashboardScreen> {
  int? _loadingTrackId;
  bool _shuffling = false;

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

  /// Lecture aléatoire de TOUTE la bibliothèque.
  ///
  /// L'ordre est tiré ici puis envoyé tel quel au lecteur : la file visible
  /// correspond exactement à ce qui sera joué.
  Future<void> _shuffleLibrary(List<Track> tracks) async {
    if (tracks.isEmpty || _shuffling) return;
    setState(() => _shuffling = true);
    try {
      final queue = shuffledLibraryQueue(tracks);
      await ref
          .read(libraryPlaybackControllerProvider)
          .playQueue(tracks: queue, initialIndex: 0);
    } catch (error) {
      if (!mounted) return;
      final message = error is AudioPlaybackException
          ? error.userMessage
          : 'La lecture n’a pas pu démarrer.';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _shuffling = false);
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
    final colors = context.colors;
    final displayName = ref.watch(
      authControllerProvider.select((state) => state.user?.displayName),
    );
    final library = ref.watch(libraryProvider);

    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          color: colors.accent,
          backgroundColor: colors.surface,
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
                  child: _ShuffleLibraryButton(
                    busy: _shuffling,
                    trackCount: library.asData?.value.length ?? 0,
                    onPressed: () =>
                        _shuffleLibrary(library.asData?.value ?? const []),
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
                  SliverToBoxAdapter(
                    child: _CenteredContent(
                      child: SizedBox(
                        height: 330,
                        child: HomeErrorState(
                          message: error is LibraryApiException
                              ? error.message
                              : 'Une erreur inattendue est survenue.',
                          onRetry: () => ref.invalidate(libraryProvider),
                        ),
                      ),
                    ),
                  ),
                ],
                data: (tracks) => tracks.isEmpty
                    ? const <Widget>[
                        SliverToBoxAdapter(
                          child: _CenteredContent(
                            child: SizedBox(
                              height: 330,
                              child: HomeEmptyState(
                                icon: Icons.library_music_outlined,
                                title: 'Votre musique vous attend',
                                message:
                                    'Les morceaux ajoutés à votre compte apparaîtront ici.',
                              ),
                            ),
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
                      ],
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
                loading: () => const <Widget>[],
                error: (_, _) => const <Widget>[],
                data: (tracks) => tracks.isEmpty
                    ? const <Widget>[]
                    : <Widget>[
                        SliverToBoxAdapter(
                          child: _CenteredContent(
                            child: HomeLibrarySections(
                              loadingTrackId: _loadingTrackId,
                              onPlayTrack: _playTrack,
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
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bouton de lecture aléatoire de toute la bibliothèque.
///
/// Masqué tant qu'il n'y a rien à jouer : proposer « Lecture aléatoire » sur
/// une bibliothèque vide serait une promesse en l'air.
class _ShuffleLibraryButton extends StatelessWidget {
  const _ShuffleLibraryButton({
    required this.busy,
    required this.trackCount,
    required this.onPressed,
  });

  final bool busy;
  final int trackCount;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    if (trackCount == 0) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HomeDesign.space16,
        HomeDesign.space16,
        HomeDesign.space16,
        0,
      ),
      child: SizedBox(
        height: 48,
        width: double.infinity,
        child: FilledButton.icon(
          key: const ValueKey('home-shuffle-library'),
          onPressed: busy ? null : onPressed,
          icon: busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.shuffle_rounded),
          label: Text(
            busy
                ? 'Préparation…'
                : 'Lecture aléatoire · $trackCount '
                      '${trackCount > 1 ? 'titres' : 'titre'}',
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
        constraints: const BoxConstraints(maxWidth: AppLayout.maxContentWidth),
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

/// En-tête : titre de page, recherche, avatar, puis salutation.
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
    final colors = context.colors;
    final theme = Theme.of(context);
    final name = displayName?.trim() ?? '';
    final hasName = name.isNotEmpty;
    final initial = hasName ? name.substring(0, 1).toUpperCase() : 'H';

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppLayout.gutter,
        18,
        AppLayout.gutter,
        20,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Accueil',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.displaySmall?.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
              SoftCircle(
                key: const ValueKey('home-search-button'),
                size: 46,
                onTap: onSearch,
                tooltip: 'Rechercher',
                semanticLabel: 'Rechercher dans la bibliothèque',
                child: Icon(
                  Icons.search_rounded,
                  size: 21,
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(width: HomeDesign.space12),
              AppAvatar(
                initial: initial,
                onTap: onProfile,
                semanticLabel: 'Ouvrir le profil',
              ),
            ],
          ),
          const SizedBox(height: HomeDesign.space24),
          // Salutation et nom restent DEUX `Text` distincts : le nom du compte
          // doit rester repérable tel quel (accessibilité et tests d'écran).
          Builder(
            builder: (context) {
              final style = theme.textTheme.headlineMedium?.copyWith(
                color: colors.textPrimary,
              );
              if (!hasName) {
                return Text(
                  'Bienvenue sur HomeSpotify',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                );
              }
              return Row(
                children: [
                  Text('$_greeting ', style: style),
                  Flexible(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: style,
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 6),
          Text(
            'Que souhaitez-vous écouter aujourd’hui ?',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// « Reprendre l'écoute » : carte sculptée, visible seulement quand une piste
/// est chargée dans le lecteur.
class ContinueListeningCard extends ConsumerWidget {
  const ContinueListeningCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mediaItem = ref.watch(mediaItemProvider).asData?.value;
    if (mediaItem == null) return const SizedBox.shrink();
    final colors = context.colors;
    final theme = Theme.of(context);
    final playback = ref.watch(playbackStateProvider).asData?.value;
    final playing = playback?.playing ?? false;
    final busy =
        playback?.processingState == AudioProcessingState.loading ||
        playback?.processingState == AudioProcessingState.buffering;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppLayout.gutter,
        0,
        AppLayout.gutter,
        26,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(title: 'Reprendre l’écoute'),
          const SizedBox(height: HomeDesign.space12),
          SoftCard(
            radius: AppRadius.tile,
            onTap: () => openPlayer(context),
            padding: const EdgeInsets.all(14),
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
              child: Row(
                key: ValueKey<String>('continue-${mediaItem.id}'),
                children: [
                  ArtworkThumb(
                    size: 82,
                    identity: 'continue-${mediaItem.id}',
                    artUri: mediaItem.artUri,
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
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontSize: 17,
                            color: colors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          mediaItem.artist ?? 'Artiste inconnu',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: HomeDesign.space12),
                        const _ContinueProgress(),
                      ],
                    ),
                  ),
                  const SizedBox(width: HomeDesign.space12),
                  SoftCircle(
                    size: 50,
                    color: colors.playSurface,
                    onTap: busy
                        ? null
                        : () {
                            final handler = ref.read(audioHandlerProvider);
                            playing ? handler.pause() : handler.play();
                          },
                    tooltip: playing ? 'Mettre en pause' : 'Reprendre',
                    child: busy
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.2,
                              color: colors.playInk,
                            ),
                          )
                        : Icon(
                            playing
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            color: colors.playInk,
                            size: 28,
                          ),
                  ),
                ],
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
    final colors = context.colors;
    final data = ref.watch(positionDataProvider).asData?.value;
    final totalMs = data?.duration.inMilliseconds ?? 0;
    final progress = totalMs <= 0
        ? 0.0
        : ((data?.position.inMilliseconds ?? 0) / totalMs).clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: LinearProgressIndicator(
        minHeight: 4,
        value: progress,
        backgroundColor: colors.surfaceSunken,
        valueColor: AlwaysStoppedAnimation<Color>(colors.accent),
      ),
    );
  }
}

/// Accès rapides — les quatre destinations existantes, présentées dans le
/// langage « clay » des planches (pas de nouvelle fonctionnalité).
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
    final colors = context.colors;
    final items = <_QuickAccessItem>[
      _QuickAccessItem(
        'Favoris',
        Icons.favorite_rounded,
        colors.clayTerracotta,
        colors.clayTerracottaInk,
        onFavorites,
      ),
      _QuickAccessItem(
        'Playlists',
        Icons.queue_music_rounded,
        colors.clayBlue,
        colors.clayBlueInk,
        onPlaylists,
      ),
      _QuickAccessItem(
        'Albums',
        Icons.album_rounded,
        colors.claySand,
        colors.claySandInk,
        onAlbums,
      ),
      _QuickAccessItem(
        'Artistes',
        Icons.groups_rounded,
        colors.clayMauve,
        colors.clayMauveInk,
        onArtists,
      ),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppLayout.gutter,
        0,
        AppLayout.gutter,
        26,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(title: 'Accès rapides'),
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
  const _QuickAccessItem(
    this.label,
    this.icon,
    this.surface,
    this.ink,
    this.onTap,
  );
  final String label;
  final IconData icon;
  final Color surface;
  final Color ink;
  final VoidCallback onTap;
}

class _QuickAccessCard extends StatelessWidget {
  const _QuickAccessCard({required this.item});
  final _QuickAccessItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SoftCard(
      color: item.surface,
      radius: AppRadius.tile,
      onTap: item.onTap,
      semanticLabel: item.label,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 104),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(item.icon, size: 27, color: item.ink),
            const SizedBox(height: HomeDesign.space16),
            Text(
              item.label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(color: item.ink),
            ),
          ],
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
      padding: const EdgeInsets.only(bottom: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppLayout.gutter),
            child: SectionHeader(
              title: 'Ajouts récents',
              actionLabel: 'Tout voir',
              onAction: onSeeAll,
            ),
          ),
          const SizedBox(height: HomeDesign.space12),
          SizedBox(
            // Hauteur = pochette (146) + titre + artiste + action « Ajouter ».
            // Marge volontaire pour les grandes polices Android.
            height: 236,
            child: ListView.separated(
              key: const PageStorageKey<String>('recent-tracks-scroll'),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                horizontal: AppLayout.gutter,
                vertical: 4,
              ),
              itemCount: visible.length,
              separatorBuilder: (_, _) => const SizedBox(width: 14),
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
    final colors = context.colors;
    final theme = Theme.of(context);
    final track = entry.track;
    final artUri = track.hasCover
        ? ref.read(libraryApiProvider).coverUri(track.id)
        : null;

    return SizedBox(
      width: 146,
      child: Semantics(
        button: true,
        label: 'Lire ${track.title} de ${track.artist}',
        child: InkWell(
          onTap: loading ? null : onTap,
          borderRadius: AppRadius.artworkRadius,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: AppRadius.artworkRadius,
                  boxShadow: colors.clayShadow,
                ),
                child: Stack(
                  children: [
                    ArtworkThumb(
                      size: 146,
                      identity: 'recent-${track.id}',
                      artUri: artUri,
                    ),
                    if (loading)
                      Positioned.fill(
                        child: ClipRRect(
                          borderRadius: AppRadius.artworkRadius,
                          child: ColoredBox(
                            color: colors.scrim,
                            child: Center(
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: colors.accent,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Text(
                track.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontSize: 14.5,
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                track.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 12.5,
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(height: 6),
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
    final colors = context.colors;
    final style = Theme.of(
      context,
    ).textTheme.labelSmall?.copyWith(fontSize: 11.5);

    if (inMyLibrary) {
      return Semantics(
        label: 'Dans votre bibliothèque',
        child: Row(
          children: [
            Icon(Icons.check_rounded, size: 14, color: colors.accent),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                'Dans votre bibliothèque',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style?.copyWith(color: colors.accent),
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
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Icon(
                Icons.library_add_outlined,
                size: 14,
                color: colors.textSecondary,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  'Ajouter',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style?.copyWith(color: colors.textSecondary),
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
    final colors = context.colors;
    final theme = Theme.of(context);
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
      padding: const EdgeInsets.symmetric(horizontal: AppLayout.gutter),
      child: SoftCard(
        padding: const EdgeInsets.all(HomeDesign.space16),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: colors.accentSoft,
                borderRadius: AppRadius.chipRadius,
              ),
              child: Icon(
                Icons.library_music_rounded,
                color: colors.accent,
                size: 21,
              ),
            ),
            const SizedBox(width: HomeDesign.space12),
            Expanded(
              child: Text(
                '${tracks.length} titres · $albums albums · $artists artistes',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
