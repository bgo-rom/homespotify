import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/home_design.dart';
import '../../library/data/library_api.dart';
import '../../library/domain/track.dart';
import '../../library/presentation/library_playback_controller.dart';
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
/// musique.
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
        backgroundColor: HomeDesign.background,
        appBar: AppBar(
          backgroundColor: HomeDesign.background,
          foregroundColor: Colors.white,
          title: const Text(
            'Rechercher',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: HomeDesign.space16,
              ),
              child: TextField(
                key: const ValueKey('catalog-search-field'),
                controller: _queryController,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                textInputAction: TextInputAction.search,
                onChanged: (value) => ref
                    .read(catalogSearchProvider.notifier)
                    .onQueryChanged(value),
                decoration: InputDecoration(
                  hintText: 'Rechercher un titre, un artiste, un album ou un ISRC…',
                  hintStyle: const TextStyle(color: Colors.white38),
                  prefixIcon: const Icon(
                    Icons.search_rounded,
                    color: Colors.white54,
                  ),
                  suffixIcon: state.query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(
                            Icons.clear_rounded,
                            color: Colors.white54,
                          ),
                          onPressed: () {
                            _queryController.clear();
                            ref
                                .read(catalogSearchProvider.notifier)
                                .onQueryChanged('');
                          },
                        ),
                  filled: true,
                  fillColor: HomeDesign.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(
                      HomeDesign.radiusMedium,
                    ),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(height: HomeDesign.space8),
            if (preview.mainPlaybackInterrupted)
              _ResumePlaybackBanner(
                onResume: () => ref
                    .read(catalogPreviewProvider.notifier)
                    .resumeMainPlayback(),
              ),
            if (state.partialResults)
              const Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: HomeDesign.space16,
                  vertical: HomeDesign.space4,
                ),
                child: Text(
                  'Résultats partiels : certains fournisseurs sont '
                  'momentanément indisponibles.',
                  key: ValueKey('catalog-partial-banner'),
                  style: TextStyle(color: Colors.orangeAccent, fontSize: 12),
                ),
              ),
            Expanded(child: _buildBody(state)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(CatalogSearchState state) {
    if (state.loading) {
      return const Center(
        child: CircularProgressIndicator(color: HomeDesign.accent),
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
        message:
            'Cherche un titre dans les catalogues officiels, écoute un aperçu, '
            'puis installe-le directement dans ta bibliothèque.',
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
      color: HomeDesign.accent,
      onRefresh: () => ref.read(catalogSearchProvider.notifier).retry(),
      child: ListView.builder(
        key: const ValueKey('catalog-search-results'),
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: HomeDesign.space32),
        itemCount: state.results.length + (state.loadingMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= state.results.length) {
            return const Padding(
              padding: EdgeInsets.all(HomeDesign.space16),
              child: Center(
                child: CircularProgressIndicator(color: HomeDesign.accent),
              ),
            );
          }
          final result = state.results[index];
          return CatalogResultCard(
            result: result,
            onInstall: () => _install(result),
            onRetry: () => _retry(result),
          );
        },
      ),
    );
  }
}

class _ResumePlaybackBanner extends StatelessWidget {
  const _ResumePlaybackBanner({required this.onResume});

  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HomeDesign.space16,
        vertical: HomeDesign.space4,
      ),
      child: Material(
        color: HomeDesign.surfaceRaised,
        borderRadius: BorderRadius.circular(HomeDesign.radiusSmall),
        child: ListTile(
          key: const ValueKey('catalog-resume-playback'),
          dense: true,
          leading: const Icon(
            Icons.play_circle_rounded,
            color: HomeDesign.accent,
          ),
          title: const Text(
            'Ta musique est en pause pendant l’aperçu.',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
          trailing: TextButton(
            onPressed: onResume,
            child: const Text(
              'Reprendre ma musique',
              style: TextStyle(color: HomeDesign.accent),
            ),
          ),
        ),
      ),
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({
    super.key,
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HomeDesign.space24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: Colors.white24),
            const SizedBox(height: HomeDesign.space12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54),
            ),
            if (actionLabel != null) ...[
              const SizedBox(height: HomeDesign.space16),
              OutlinedButton(
                key: const ValueKey('catalog-search-retry'),
                onPressed: onAction,
                child: Text(
                  actionLabel!,
                  style: const TextStyle(color: HomeDesign.accent),
                ),
              ),
            ],
          ],
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

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HomeDesign.space16,
        vertical: HomeDesign.space4,
      ),
      child: Material(
        color: HomeDesign.surface,
        borderRadius: BorderRadius.circular(HomeDesign.radiusMedium),
        child: Padding(
          padding: const EdgeInsets.all(HomeDesign.space12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(HomeDesign.radiusSmall),
                    child: SizedBox(
                      width: 56,
                      height: 56,
                      child: result.imageUrl == null
                          ? const ColoredBox(
                              color: HomeDesign.surfaceMuted,
                              child: Icon(
                                Icons.music_note_rounded,
                                color: Colors.white38,
                              ),
                            )
                          : Image.network(
                              result.imageUrl!,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => const ColoredBox(
                                color: HomeDesign.surfaceMuted,
                                child: Icon(
                                  Icons.music_note_rounded,
                                  color: Colors.white38,
                                ),
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(width: HomeDesign.space12),
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
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (result.explicit == true)
                              const Padding(
                                padding: EdgeInsets.only(
                                  left: HomeDesign.space4,
                                ),
                                child: Icon(
                                  Icons.explicit_rounded,
                                  size: 16,
                                  color: Colors.white38,
                                ),
                              ),
                          ],
                        ),
                        Text(
                          [
                            if (result.artistLabel.isNotEmpty)
                              result.artistLabel,
                            if (result.album != null) result.album!,
                            if (duration.isNotEmpty) duration,
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: HomeDesign.space4),
                        Wrap(
                          spacing: HomeDesign.space4,
                          runSpacing: HomeDesign.space4,
                          children: [
                            // UNIQUEMENT les catalogues CONFIRMED/LINK_FOUND :
                            // UNKNOWN n'est jamais présenté comme un fait.
                            for (final link in result.positiveLinks)
                              _Badge(
                                key: ValueKey('platform-badge-${link.platform}'),
                                label:
                                    _platformLabels[link.platform] ??
                                    link.platform,
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
                  if (hasPreview)
                    IconButton(
                      key: ValueKey('preview-button-${result.canonicalKey}'),
                      tooltip: isPreviewActive
                          ? 'Mettre l’aperçu en pause'
                          : 'Écouter un aperçu',
                      icon: Icon(
                        isPreviewActive
                            ? Icons.pause_circle_rounded
                            : Icons.play_circle_outline_rounded,
                        color: HomeDesign.accent,
                      ),
                      onPressed: () => ref
                          .read(catalogPreviewProvider.notifier)
                          .toggle(result.canonicalKey, result.preview!),
                    )
                  else
                    const Tooltip(
                      key: ValueKey('preview-unavailable'),
                      message: 'Aucun aperçu disponible pour ce titre',
                      child: Padding(
                        padding: EdgeInsets.all(HomeDesign.space8),
                        child: Icon(
                          Icons.music_off_rounded,
                          color: Colors.white24,
                        ),
                      ),
                    ),
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
        ),
      ),
    );
  }
}

/// Bouton d'installation : un seul contrôle, tous les états.
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
    if (install.stage.isBusy) {
      // `onPressed: null` : pendant un job actif, un second appui est
      // structurellement impossible, pas seulement ignoré.
      return IconButton(
        key: ValueKey('install-busy-$canonicalKey'),
        tooltip: install.message,
        onPressed: null,
        icon: const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: HomeDesign.accent,
          ),
        ),
      );
    }
    if (install.stage.isInstalled) {
      return IconButton(
        key: ValueKey('install-done-$canonicalKey'),
        tooltip: install.stage == TrackInstallStage.reused
            ? 'Déjà dans votre bibliothèque'
            : 'Installé',
        onPressed: null,
        icon: const Icon(Icons.check_circle_rounded, color: Colors.greenAccent),
      );
    }
    if (install.stage == TrackInstallStage.failed) {
      return IconButton(
        key: ValueKey('install-retry-$canonicalKey'),
        tooltip: 'Réessayer',
        onPressed: onRetry,
        icon: const Icon(Icons.refresh_rounded, color: Colors.orangeAccent),
      );
    }
    return IconButton(
      key: ValueKey('install-button-$canonicalKey'),
      tooltip: 'Installer ce titre',
      onPressed: onInstall,
      icon: const Icon(
        Icons.download_for_offline_outlined,
        color: Colors.white70,
      ),
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
    final message = install.message;
    return Padding(
      padding: const EdgeInsets.only(top: HomeDesign.space8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (message != null && message.isNotEmpty)
            Text(
              message,
              key: ValueKey('install-message-$canonicalKey'),
              style: TextStyle(
                fontSize: 12,
                color: switch (install.stage) {
                  TrackInstallStage.failed => Colors.orangeAccent,
                  TrackInstallStage.success ||
                  TrackInstallStage.reused => Colors.greenAccent,
                  _ => Colors.white70,
                },
              ),
            ),
          if (install.stage == TrackInstallStage.downloading ||
              install.stage == TrackInstallStage.fallback)
            Padding(
              padding: const EdgeInsets.only(top: HomeDesign.space4),
              child: LinearProgressIndicator(
                key: ValueKey('install-progress-$canonicalKey'),
                value: install.progress <= 0 ? null : install.progress / 100,
                backgroundColor: HomeDesign.surfaceMuted,
                color: HomeDesign.accent,
                minHeight: 3,
              ),
            ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({super.key, required this.label, this.accent = false});

  final String label;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: accent
            ? HomeDesign.accent.withValues(alpha: 0.18)
            : HomeDesign.surfaceMuted,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: accent ? HomeDesign.accent : Colors.white60,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
