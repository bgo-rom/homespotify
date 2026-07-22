import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/home_design.dart';
import '../../library/data/library_api.dart';
import '../application/catalog_search_controller.dart';
import '../domain/catalog_models.dart';
import 'catalog_preview_controller.dart';
import 'request_from_catalog_sheet.dart';

/// Identités (titre|artiste normalisés) de la bibliothèque du compte, pour le
/// badge « Dans ma bibliothèque » (lecture seule, jamais bloquant).
final _libraryIdentitiesProvider = Provider<Set<String>>((ref) {
  final tracks = ref.watch(libraryProvider).asData?.value ?? const [];
  return {
    for (final track in tracks)
      '${track.title.trim().toLowerCase()}|${track.artist.trim().toLowerCase()}',
  };
});

String _identityOf(CatalogResult result) =>
    '${result.title.trim().toLowerCase()}|'
    '${(result.artistNames.isEmpty ? '' : result.artistNames.first).trim().toLowerCase()}';

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

/// Écran « Rechercher » du catalogue multi-fournisseurs.
class CatalogSearchScreen extends ConsumerStatefulWidget {
  const CatalogSearchScreen({super.key});

  @override
  ConsumerState<CatalogSearchScreen> createState() =>
      _CatalogSearchScreenState();
}

class _CatalogSearchScreenState extends ConsumerState<CatalogSearchScreen> {
  final TextEditingController _queryController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

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

  Future<void> _openRequestSheet(CatalogResult result) async {
    await ref.read(catalogPreviewProvider.notifier).stop();
    if (!mounted) return;
    final sent = await showCatalogRequestSheet(
      context,
      ref,
      CatalogRequestSheetData.fromTrack(result),
    );
    if (sent && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Demande envoyée.'),
          action: SnackBarAction(
            label: 'Mes demandes',
            onPressed: () => context.push('/requests'),
          ),
        ),
      );
    }
  }

  void _openDetail(CatalogResult result) {
    final reference = result.primaryReference;
    if (reference == null) return;
    final path = switch (result.entityType) {
      CatalogEntityType.artist =>
        '/catalog-search/artists/${reference.provider}/${reference.externalId}',
      CatalogEntityType.album =>
        '/catalog-search/albums/${reference.provider}/${reference.externalId}',
      _ => null,
    };
    if (path != null) context.push(path);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(catalogSearchProvider);
    final preview = ref.watch(catalogPreviewProvider);
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
                  hintText: 'Titre, artiste, album ou ISRC…',
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
            _TypeTabs(
              selected: state.type,
              onSelected: (type) =>
                  ref.read(catalogSearchProvider.notifier).onTypeChanged(type),
            ),
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
            'Recherche des titres, artistes et albums dans les catalogues '
            'officiels, puis crée une demande pour ta bibliothèque.',
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
            onTap: result.entityType == CatalogEntityType.track
                ? null
                : () => _openDetail(result),
            onRequest: result.entityType == CatalogEntityType.track
                ? () => _openRequestSheet(result)
                : null,
          );
        },
      ),
    );
  }
}

class _TypeTabs extends StatelessWidget {
  const _TypeTabs({required this.selected, required this.onSelected});

  final CatalogEntityType selected;
  final ValueChanged<CatalogEntityType> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: HomeDesign.space16),
        children: [
          for (final type in CatalogEntityType.values)
            Padding(
              padding: const EdgeInsets.only(right: HomeDesign.space8),
              child: ChoiceChip(
                key: ValueKey('catalog-tab-${type.wireName}'),
                label: Text(type.label),
                selected: type == selected,
                onSelected: (_) => onSelected(type),
                selectedColor: HomeDesign.accent.withValues(alpha: 0.25),
                labelStyle: TextStyle(
                  color: type == selected ? HomeDesign.accent : Colors.white70,
                ),
                backgroundColor: HomeDesign.surface,
                side: BorderSide.none,
              ),
            ),
        ],
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

/// Carte d'un résultat de recherche (titre, artiste, album ou playlist).
class CatalogResultCard extends ConsumerWidget {
  const CatalogResultCard({
    super.key,
    required this.result,
    this.onTap,
    this.onRequest,
  });

  final CatalogResult result;
  final VoidCallback? onTap;
  final VoidCallback? onRequest;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final owned =
        result.entityType == CatalogEntityType.track &&
        ref.watch(_libraryIdentitiesProvider).contains(_identityOf(result));
    final requested = ref
        .watch(catalogRequestedKeysProvider)
        .contains(result.canonicalKey);
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
        child: InkWell(
          borderRadius: BorderRadius.circular(HomeDesign.radiusMedium),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(HomeDesign.space12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(HomeDesign.radiusSmall),
                  child: SizedBox(
                    width: 56,
                    height: 56,
                    child: result.imageUrl == null
                        ? ColoredBox(
                            color: HomeDesign.surfaceMuted,
                            child: Icon(switch (result.entityType) {
                              CatalogEntityType.artist => Icons.person_rounded,
                              CatalogEntityType.album => Icons.album_rounded,
                              CatalogEntityType.playlist =>
                                Icons.queue_music_rounded,
                              _ => Icons.music_note_rounded,
                            }, color: Colors.white38),
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
                              padding: EdgeInsets.only(left: HomeDesign.space4),
                              child: Icon(
                                Icons.explicit_rounded,
                                size: 16,
                                color: Colors.white38,
                              ),
                            ),
                        ],
                      ),
                      if (result.artistLabel.isNotEmpty || result.album != null)
                        Text(
                          [
                            if (result.artistLabel.isNotEmpty)
                              result.artistLabel,
                            if (result.entityType == CatalogEntityType.track &&
                                result.album != null)
                              result.album!,
                            if (duration.isNotEmpty) duration,
                            if (result.trackCount != null)
                              '${result.trackCount} pistes',
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
                          // UNIQUEMENT les plateformes CONFIRMED/LINK_FOUND :
                          // UNKNOWN n'est jamais affiché comme indisponible.
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
                          if (requested)
                            const _Badge(
                              key: ValueKey('badge-requested'),
                              label: 'Déjà demandé',
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
                        ? 'Arrêter l’aperçu'
                        : 'Écouter un aperçu',
                    icon: Icon(
                      isPreviewActive
                          ? Icons.stop_circle_rounded
                          : Icons.play_circle_outline_rounded,
                      color: HomeDesign.accent,
                    ),
                    onPressed: () => ref
                        .read(catalogPreviewProvider.notifier)
                        .toggle(result.canonicalKey, result.preview!),
                  ),
                if (onRequest != null && !owned && !requested)
                  IconButton(
                    key: ValueKey('request-button-${result.canonicalKey}'),
                    tooltip: 'Demander ce titre',
                    icon: const Icon(
                      Icons.add_circle_outline_rounded,
                      color: Colors.white70,
                    ),
                    onPressed: onRequest,
                  ),
              ],
            ),
          ),
        ),
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
