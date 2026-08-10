import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shapes.dart';
import '../../../core/widgets/clay_header.dart';
import '../../../core/widgets/soft_surface.dart';
import '../../library/data/library_api.dart';
import '../../library/domain/track.dart';
import '../../library/presentation/library_playback_controller.dart';
import '../../player/presentation/widgets/mini_player.dart';
import '../application/catalog_search_controller.dart';
import '../application/track_install_controller.dart';
import '../domain/catalog_models.dart';
import '../domain/track_install_state.dart';
import 'catalog_preview_controller.dart';

/// Identités (titre|artiste normalisés) de la bibliothèque du compte, pour le
/// badge « Dans ma bibliothèque » (lecture seule, jamais bloquant).
final _libraryIdentitiesProvider = Provider<Set<String>>((ref) {
  final tracks = ref.watch(libraryProvider).asData?.value ?? const [];
  return {
    for (final track in tracks) trackIdentityKey(track.title, track.artist),
  };
});

String _identityOf(CatalogResult result) => trackIdentityKey(
  result.title,
  result.artistNames.isEmpty ? '' : result.artistNames.first,
);

String _formatDuration(int? durationMs) {
  if (durationMs == null || durationMs <= 0) return '';
  final total = Duration(milliseconds: durationMs);
  final minutes = total.inMinutes;
  final seconds = total.inSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

const _platformLabels = <String, String>{
  'spotify': 'Spotify',
  'apple_music': 'Apple Music',
  'deezer': 'Deezer',
  'tidal': 'TIDAL',
  'bandcamp': 'Bandcamp',
  'qobuz': 'Qobuz',
  'musicbrainz': 'MusicBrainz',
};

/// Écran « Rechercher » : UNIQUE point d'entrée pour trouver et installer une
/// musique. Refonte Direction 33 — même logique, même flux serveur.
///
/// Un seul type de résultat (des pistes), donc aucun onglet. Le bouton
/// Installer appelle directement le moteur de téléchargement avec l'identité
/// complète du morceau sélectionné : il n'existe plus ni demande, ni
/// validation, ni saisie d'URL.
class CatalogSearchScreen extends ConsumerStatefulWidget {
  const CatalogSearchScreen({super.key});

  @override
  ConsumerState<CatalogSearchScreen> createState() =>
      _CatalogSearchScreenState();
}

class _CatalogSearchScreenState extends ConsumerState<CatalogSearchScreen> {
  final TextEditingController _queryController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  /// Résultats déjà rapprochés d'un job serveur : la reprise d'état ne doit
  /// pas rejouer un appel réseau à chaque reconstruction.
  String _restoredSignature = '';

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _queryController.dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 320) {
      ref.read(catalogSearchProvider.notifier).loadMore();
    }
  }

  /// Rattache les jobs serveur encore actifs aux résultats affichés.
  ///
  /// L'utilisateur peut quitter l'écran pendant une installation : à son
  /// retour, la carte doit retrouver l'état réel du job, pas repartir de zéro.
  void _restoreActiveJobs(List<CatalogResult> results) {
    if (results.isEmpty) return;
    final signature = results.map((result) => result.canonicalKey).join('|');
    if (signature == _restoredSignature) return;
    _restoredSignature = signature;
    // Un état retrouvé n'est pas une action de l'utilisateur : la carte
    // l'affiche, mais aucune confirmation ne surgit. Un clic explicite sur
    // Installer lève cette marque pour la piste concernée.
    _announced.addAll(results.map((result) => result.canonicalKey));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(trackInstallProvider.notifier).restoreFor(results);
    });
  }

  /// Clés déjà annoncées : un job ne produit qu'UNE confirmation, même si le
  /// flux réémet son état terminal.
  final Set<String> _announced = {};

  Future<void> _install(CatalogResult result) async {
    // La preview d'un morceau et son installation n'ont aucune raison de
    // cohabiter : le son s'arrête dès que l'installation démarre.
    await ref.read(catalogPreviewProvider.notifier).stop();
    _announced.remove(result.canonicalKey);
    await ref.read(trackInstallProvider.notifier).install(result);
  }

  Future<void> _retry(CatalogResult result) async {
    _announced.remove(result.canonicalKey);
    await ref.read(trackInstallProvider.notifier).retry(result);
  }

  /// Confirmation finale, déclenchée par la transition vers un état terminal.
  ///
  /// L'annonce ne peut pas être faite à la fin de `install()` : le job vit
  /// côté serveur et son issue arrive plus tard, par le flux SSE.
  void _announceTerminalStates(Map<String, TrackInstallState> installs) {
    for (final entry in installs.entries) {
      final install = entry.value;
      if (install.stage.isBusy || install.stage == TrackInstallStage.idle) {
        continue;
      }
      if (!_announced.add(entry.key)) continue;
      switch (install.stage) {
        case TrackInstallStage.success:
          _showSuccess(install, reused: false);
        case TrackInstallStage.reused:
          _showSuccess(install, reused: true);
        case TrackInstallStage.failed:
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              key: const ValueKey('catalog-install-failed'),
              content: Text(install.message ?? 'L’installation a échoué.'),
            ),
          );
        case TrackInstallStage.idle:
        case TrackInstallStage.creating:
        case TrackInstallStage.resolving:
        case TrackInstallStage.downloading:
        case TrackInstallStage.fallback:
        case TrackInstallStage.importing:
          break;
      }
    }
  }

  void _showSuccess(TrackInstallState install, {required bool reused}) {
    final trackId = install.trackId;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        key: ValueKey(
          reused ? 'catalog-install-reused' : 'catalog-install-success',
        ),
        duration: const Duration(seconds: 6),
        content: Text(
          reused
              ? 'Ce titre est déjà présent dans votre bibliothèque.'
              : '${install.label} a bien été installé dans votre bibliothèque.',
        ),
        action: trackId == null
            ? SnackBarAction(
                label: 'Voir la bibliothèque',
                onPressed: () => context.push('/library'),
              )
            : SnackBarAction(
                label: 'Lire maintenant',
                onPressed: () => _playNow(trackId),
              ),
      ),
    );
  }

  Future<void> _playNow(int trackId) async {
    await ref.read(catalogPreviewProvider.notifier).stop();
    final tracks = await ref.read(libraryProvider.future);
    if (!mounted) return;
    final index = tracks.indexWhere((Track track) => track.id == trackId);
    if (index < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('La piste n’est pas encore visible en bibliothèque.'),
        ),
      );
      return;
    }
    await ref
        .read(libraryPlaybackControllerProvider)
        .playQueue(tracks: [tracks[index]], initialIndex: 0);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final state = ref.watch(catalogSearchProvider);
    final preview = ref.watch(catalogPreviewProvider);
    ref.listen<Map<String, TrackInstallState>>(
      trackInstallProvider,
      (_, next) => _announceTerminalStates(next),
    );
    _restoreActiveJobs(state.results);
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) ref.read(catalogPreviewProvider.notifier).stop();
      },
      child: Scaffold(
        backgroundColor: colors.background,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              ClayHeader(
                title: 'Rechercher',
                subtitle: 'Trouve un titre et installe-le en un geste',
                onBack: () => Navigator.of(context).maybePop(),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppLayout.gutter,
                  2,
                  AppLayout.gutter,
                  6,
                ),
                child: _SearchField(
                  controller: _queryController,
                  hasQuery: state.query.isNotEmpty,
                  onChanged: (value) => ref
                      .read(catalogSearchProvider.notifier)
                      .onQueryChanged(value),
                  onClear: () {
                    _queryController.clear();
                    ref
                        .read(catalogSearchProvider.notifier)
                        .onQueryChanged('');
                  },
                ),
              ),
              if (preview.mainPlaybackInterrupted)
                _ResumePlaybackBanner(
                  onResume: () => ref
                      .read(catalogPreviewProvider.notifier)
                      .resumeMainPlayback(),
                ),
              if (state.partialResults) const _PartialResultsBanner(),
              Expanded(child: _buildBody(state)),
            ],
          ),
        ),
        bottomNavigationBar: const MiniPlayer(),
      ),
    );
  }

  Widget _buildBody(CatalogSearchState state) {
    final colors = context.colors;
    if (state.loading) {
      return Center(
        child: CircularProgressIndicator(color: colors.accent),
      );
    }
    if (state.error != null) {
      return _CenteredMessage(
        key: const ValueKey('catalog-search-error'),
        icon: Icons.cloud_off_rounded,
        message: state.error!,
        actionLabel: 'Réessayer',
        onAction: () => ref.read(catalogSearchProvider.notifier).retry(),
      );
    }
    if (state.isQueryTooShort) {
      return const _CenteredMessage(
        icon: Icons.short_text_rounded,
        message: 'Tape au moins 2 caractères.',
      );
    }
    if (!state.searched) {
      return const _CenteredMessage(
        key: ValueKey('catalog-search-initial'),
        icon: Icons.travel_explore_rounded,
        title: 'Cherche dans les catalogues officiels',
        message:
            'Trouve un titre, écoute un aperçu, puis installe-le directement '
            'dans ta bibliothèque.',
      );
    }
    if (state.results.isEmpty) {
      return const _CenteredMessage(
        key: ValueKey('catalog-search-empty'),
        icon: Icons.search_off_rounded,
        message: 'Aucun résultat pour cette recherche.',
      );
    }
    return RefreshIndicator(
      color: colors.accent,
      backgroundColor: colors.surface,
      onRefresh: () => ref.read(catalogSearchProvider.notifier).retry(),
      child: ListView.builder(
        key: const ValueKey('catalog-search-results'),
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          AppLayout.gutter,
          4,
          AppLayout.gutter,
          24,
        ),
        itemCount: state.results.length + (state.loadingMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= state.results.length) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: CircularProgressIndicator(color: colors.accent),
              ),
            );
          }
          final result = state.results[index];
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: AppLayout.maxContentWidth,
              ),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: CatalogResultCard(
                  result: result,
                  onInstall: () => _install(result),
                  onRetry: () => _retry(result),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Champ de recherche sculpté : creux « clay », une seule surface, aucun trait.
class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.hasQuery,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final bool hasQuery;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceSunken,
        borderRadius: AppRadius.cardRadius,
      ),
      child: TextField(
        key: const ValueKey('catalog-search-field'),
        controller: controller,
        autofocus: true,
        style: theme.textTheme.bodyLarge?.copyWith(color: colors.textPrimary),
        textInputAction: TextInputAction.search,
        cursorColor: colors.accent,
        onChanged: onChanged,
        decoration: InputDecoration(
          isCollapsed: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 15),
          hintText: 'Rechercher un titre, un artiste, un album ou un ISRC…',
          hintStyle: theme.textTheme.bodyMedium?.copyWith(
            color: colors.textTertiary,
          ),
          prefixIcon: Icon(Icons.search_rounded, color: colors.textSecondary),
          suffixIcon: !hasQuery
              ? null
              : IconButton(
                  icon: Icon(Icons.clear_rounded, color: colors.textSecondary),
                  onPressed: onClear,
                ),
          filled: false,
          border: InputBorder.none,
          focusedBorder: InputBorder.none,
          enabledBorder: InputBorder.none,
        ),
      ),
    );
  }
}

/// Rappel « ta musique est en pause pendant l'aperçu » — carte sculptée.
class _ResumePlaybackBanner extends StatelessWidget {
  const _ResumePlaybackBanner({required this.onResume});

  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppLayout.gutter, 2, AppLayout.gutter, 6),
      child: SoftCard(
        key: const ValueKey('catalog-resume-playback'),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.play_circle_rounded, color: colors.accent, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Ta musique est en pause pendant l’aperçu.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: onResume,
              style: TextButton.styleFrom(
                foregroundColor: colors.accent,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 36),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                'Reprendre',
                style: theme.textTheme.labelLarge?.copyWith(color: colors.accent),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bandeau « résultats partiels » : un fournisseur est momentanément absent.
class _PartialResultsBanner extends StatelessWidget {
  const _PartialResultsBanner();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppLayout.gutter, 2, AppLayout.gutter, 6),
      child: Row(
        key: const ValueKey('catalog-partial-banner'),
        children: [
          Icon(Icons.cloud_queue_rounded, size: 16, color: colors.textTertiary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Résultats partiels : certains fournisseurs sont momentanément '
              'indisponibles.',
              style: theme.textTheme.labelMedium?.copyWith(
                color: colors.textTertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// État centré (initial, vide, erreur) en langage Direction 33.
class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({
    super.key,
    required this.icon,
    required this.message,
    this.title,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String message;
  final String? title;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SoftCircle(
                size: 84,
                child: Icon(icon, size: 34, color: colors.textTertiary),
              ),
              const SizedBox(height: 20),
              if (title != null) ...[
                Text(
                  title!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
              ],
              Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              if (actionLabel != null) ...[
                const SizedBox(height: 20),
                FilledButton(
                  key: const ValueKey('catalog-search-retry'),
                  onPressed: onAction,
                  style: FilledButton.styleFrom(
                    backgroundColor: colors.accent,
                    foregroundColor: colors.onAccent,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: AppRadius.chipRadius,
                    ),
                  ),
                  child: Text(actionLabel!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Carte d'un titre : pochette, identité, aperçu et installation.
///
/// Le suivi d'installation est INTÉGRÉ à la carte — il n'existe plus d'écran
/// de file séparé.
class CatalogResultCard extends ConsumerWidget {
  const CatalogResultCard({
    super.key,
    required this.result,
    required this.onInstall,
    required this.onRetry,
  });

  final CatalogResult result;
  final VoidCallback onInstall;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final theme = Theme.of(context);
    final owned = ref.watch(_libraryIdentitiesProvider).contains(
      _identityOf(result),
    );
    final install =
        ref.watch(trackInstallProvider)[result.canonicalKey] ??
        TrackInstallState.idle;
    final preview = ref.watch(catalogPreviewProvider);
    final hasPreview =
        result.preview != null && !result.preview!.requiresOfficialSdk;
    final isPreviewActive = preview.isActiveFor(result.canonicalKey);
    final duration = _formatDuration(result.durationMs);

    return SoftCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _CatalogArtwork(imageUrl: result.imageUrl, size: 58),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            result.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: colors.textPrimary,
                            ),
                          ),
                        ),
                        if (result.explicit == true)
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Icon(
                              Icons.explicit_rounded,
                              size: 16,
                              color: colors.textTertiary,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (result.artistLabel.isNotEmpty) result.artistLabel,
                        if (result.album != null) result.album!,
                        if (duration.isNotEmpty) duration,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        // UNIQUEMENT les catalogues CONFIRMED/LINK_FOUND :
                        // UNKNOWN n'est jamais présenté comme un fait.
                        for (final link in result.positiveLinks)
                          _Badge(
                            key: ValueKey('platform-badge-${link.platform}'),
                            label:
                                _platformLabels[link.platform] ?? link.platform,
                          ),
                        if (owned)
                          const _Badge(
                            key: ValueKey('badge-owned'),
                            label: 'Dans ma bibliothèque',
                            accent: true,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (hasPreview)
                SoftCircle(
                  key: ValueKey('preview-button-${result.canonicalKey}'),
                  size: 44,
                  tooltip: isPreviewActive
                      ? 'Mettre l’aperçu en pause'
                      : 'Écouter un aperçu',
                  onTap: () => ref
                      .read(catalogPreviewProvider.notifier)
                      .toggle(result.canonicalKey, result.preview!),
                  child: Icon(
                    isPreviewActive
                        ? Icons.pause_circle_rounded
                        : Icons.play_circle_outline_rounded,
                    color: colors.accent,
                  ),
                )
              else
                Tooltip(
                  key: const ValueKey('preview-unavailable'),
                  message: 'Aucun aperçu disponible pour ce titre',
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: Icon(
                      Icons.music_off_rounded,
                      color: colors.textTertiary,
                    ),
                  ),
                ),
              const SizedBox(width: 10),
              _InstallButton(
                canonicalKey: result.canonicalKey,
                install: install,
                onInstall: onInstall,
                onRetry: onRetry,
              ),
            ],
          ),
          if (install.stage != TrackInstallStage.idle)
            _InstallProgress(
              canonicalKey: result.canonicalKey,
              install: install,
            ),
        ],
      ),
    );
  }
}

/// Pochette externe (CDN du catalogue) au langage Direction 33 : rayon,
/// creux et icône de repli identiques à [ArtworkThumb], mais SANS
/// authentification (l'URL n'appartient pas au serveur).
class _CatalogArtwork extends StatelessWidget {
  const _CatalogArtwork({required this.imageUrl, required this.size});

  final String? imageUrl;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final placeholder = ColoredBox(
      color: colors.surfaceSunken,
      child: Icon(
        Icons.music_note_rounded,
        color: colors.textTertiary,
        size: size * 0.34,
      ),
    );
    final url = imageUrl;
    return ClipRRect(
      borderRadius: AppRadius.artworkRadius,
      child: SizedBox(
        width: size,
        height: size,
        child: url == null
            ? placeholder
            : Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => placeholder,
              ),
      ),
    );
  }
}

/// Bouton d'installation sculpté : un seul contrôle, tous les états.
class _InstallButton extends StatelessWidget {
  const _InstallButton({
    required this.canonicalKey,
    required this.install,
    required this.onInstall,
    required this.onRetry,
  });

  final String canonicalKey;
  final TrackInstallState install;
  final VoidCallback onInstall;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;

    if (install.stage.isBusy) {
      // Pas d'`onTap` : pendant un job actif, un second appui est
      // structurellement impossible, pas seulement ignoré.
      return SoftCircle(
        key: ValueKey('install-busy-$canonicalKey'),
        size: 46,
        tooltip: install.message,
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: colors.accent,
          ),
        ),
      );
    }
    if (install.stage.isInstalled) {
      return SoftCircle(
        key: ValueKey('install-done-$canonicalKey'),
        size: 46,
        color: colors.accentSoft,
        tooltip: install.stage == TrackInstallStage.reused
            ? 'Déjà dans votre bibliothèque'
            : 'Installé',
        child: Icon(Icons.check_rounded, color: colors.accent),
      );
    }
    if (install.stage == TrackInstallStage.failed) {
      return SoftCircle(
        key: ValueKey('install-retry-$canonicalKey'),
        size: 46,
        tooltip: 'Réessayer',
        onTap: onRetry,
        child: Icon(Icons.refresh_rounded, color: colors.danger),
      );
    }
    return SoftCircle(
      key: ValueKey('install-button-$canonicalKey'),
      size: 46,
      color: colors.accent,
      tooltip: 'Installer ce titre',
      onTap: onInstall,
      child: Icon(Icons.arrow_downward_rounded, color: colors.onAccent),
    );
  }
}

/// Ligne d'état sous la carte : libellé d'étape + barre de progression.
class _InstallProgress extends StatelessWidget {
  const _InstallProgress({required this.canonicalKey, required this.install});

  final String canonicalKey;
  final TrackInstallState install;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    final message = install.message;
    final Color tone = switch (install.stage) {
      TrackInstallStage.failed => colors.danger,
      TrackInstallStage.success ||
      TrackInstallStage.reused => colors.accent,
      _ => colors.textSecondary,
    };
    final busy = install.stage.isBusy;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (message != null && message.isNotEmpty)
            Row(
              children: [
                if (busy) ...[
                  _StageDot(color: colors.accent),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    message,
                    key: ValueKey('install-message-$canonicalKey'),
                    style: theme.textTheme.labelMedium?.copyWith(color: tone),
                  ),
                ),
              ],
            ),
          if (install.stage == TrackInstallStage.downloading ||
              install.stage == TrackInstallStage.fallback)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  key: ValueKey('install-progress-$canonicalKey'),
                  value: install.progress <= 0 ? null : install.progress / 100,
                  backgroundColor: colors.surfaceSunken,
                  color: colors.accent,
                  minHeight: 5,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Petite pastille pleine qui signale une étape active (Antra travaille).
class _StageDot extends StatelessWidget {
  const _StageDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({super.key, required this.label, this.accent = false});

  final String label;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: accent ? colors.accentSoft : colors.surfaceSunken,
        borderRadius: AppRadius.chipRadius,
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: accent ? colors.accent : colors.textSecondary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
