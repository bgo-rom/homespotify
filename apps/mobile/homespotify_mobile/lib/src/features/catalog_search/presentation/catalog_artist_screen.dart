import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/theme/home_design.dart';
import '../data/catalog_search_api.dart';
import '../domain/catalog_models.dart';

/// Fiche artiste chargée depuis /api/discovery (provider + id validés).
final catalogArtistProvider = FutureProvider.autoDispose
    .family<CatalogArtistDetail, CatalogEntityRef>((ref, reference) {
      return ref.watch(catalogSearchApiProvider).fetchArtist(reference);
    });

final catalogArtistAlbumsProvider = FutureProvider.autoDispose
    .family<CatalogAlbumPage, CatalogEntityRef>((ref, reference) {
      return ref.watch(catalogSearchApiProvider).fetchArtistAlbums(reference);
    });

class CatalogArtistScreen extends ConsumerWidget {
  const CatalogArtistScreen({
    super.key,
    required this.provider,
    required this.artistId,
  });

  final String provider;
  final String artistId;

  CatalogEntityRef get _reference => CatalogEntityRef(
    provider: provider,
    entityType: CatalogEntityType.artist,
    externalId: artistId,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artist = ref.watch(catalogArtistProvider(_reference));
    final albums = ref.watch(catalogArtistAlbumsProvider(_reference));
    return Scaffold(
      backgroundColor: HomeDesign.background,
      appBar: AppBar(
        backgroundColor: HomeDesign.background,
        foregroundColor: Colors.white,
        title: Text(
          artist.asData?.value.name ?? 'Artiste',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: artist.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: HomeDesign.accent),
        ),
        error: (error, _) => _ErrorRetry(
          message: error.toString(),
          onRetry: () => ref.invalidate(catalogArtistProvider(_reference)),
        ),
        data: (detail) => ListView(
          key: const ValueKey('catalog-artist-content'),
          padding: const EdgeInsets.all(HomeDesign.space16),
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 40,
                  backgroundColor: HomeDesign.surfaceMuted,
                  foregroundImage: detail.imageUrl == null
                      ? null
                      : NetworkImage(detail.imageUrl!),
                  child: const Icon(
                    Icons.person_rounded,
                    color: Colors.white38,
                    size: 36,
                  ),
                ),
                const SizedBox(width: HomeDesign.space16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        detail.name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (detail.disambiguation != null)
                        Text(
                          detail.disambiguation!,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                      if (detail.genres.isNotEmpty)
                        Text(
                          detail.genres.take(4).join(' · '),
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 12,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (detail.links.any((link) => link.status.isPositive)) ...[
              const SizedBox(height: HomeDesign.space16),
              Wrap(
                spacing: HomeDesign.space8,
                runSpacing: HomeDesign.space8,
                children: [
                  for (final link in detail.links.where(
                    (link) => link.status.isPositive && link.url != null,
                  ))
                    ActionChip(
                      key: ValueKey('artist-link-${link.platform}'),
                      backgroundColor: HomeDesign.surface,
                      label: Text(
                        link.platform,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                      avatar: const Icon(
                        Icons.open_in_new_rounded,
                        size: 14,
                        color: Colors.white54,
                      ),
                      onPressed: () => _openExternal(link.url!),
                    ),
                ],
              ),
            ],
            const SizedBox(height: HomeDesign.space20),
            const Text(
              'Discographie',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: HomeDesign.space8),
            albums.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(HomeDesign.space24),
                child: Center(
                  child: CircularProgressIndicator(color: HomeDesign.accent),
                ),
              ),
              error: (error, _) => _ErrorRetry(
                message: 'Discographie indisponible.',
                onRetry: () =>
                    ref.invalidate(catalogArtistAlbumsProvider(_reference)),
              ),
              data: (page) => page.items.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(HomeDesign.space16),
                      child: Text(
                        'Aucun album trouvé chez ce fournisseur.',
                        style: TextStyle(color: Colors.white54),
                      ),
                    )
                  : Column(
                      key: const ValueKey('catalog-artist-albums'),
                      children: [
                        for (final album in page.items)
                          ListTile(
                            key: ValueKey(
                              'artist-album-${album.reference?.externalId}',
                            ),
                            contentPadding: EdgeInsets.zero,
                            leading: ClipRRect(
                              borderRadius: BorderRadius.circular(
                                HomeDesign.radiusSmall,
                              ),
                              child: SizedBox(
                                width: 48,
                                height: 48,
                                child: album.imageUrl == null
                                    ? const ColoredBox(
                                        color: HomeDesign.surfaceMuted,
                                        child: Icon(
                                          Icons.album_rounded,
                                          color: Colors.white38,
                                        ),
                                      )
                                    : Image.network(
                                        album.imageUrl!,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, _, _) =>
                                            const ColoredBox(
                                              color: HomeDesign.surfaceMuted,
                                              child: Icon(
                                                Icons.album_rounded,
                                                color: Colors.white38,
                                              ),
                                            ),
                                      ),
                              ),
                            ),
                            title: Text(
                              album.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white),
                            ),
                            subtitle: Text(
                              [
                                if (album.albumType != null) album.albumType!,
                                if (album.releaseDate != null)
                                  album.releaseDate!.split('-').first,
                                if (album.trackCount != null)
                                  '${album.trackCount} pistes',
                              ].join(' · '),
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 12,
                              ),
                            ),
                            onTap: album.reference == null
                                ? null
                                : () => context.push(
                                    '/catalog-search/albums/'
                                    '${album.reference!.provider}/'
                                    '${album.reference!.externalId}',
                                  ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openExternal(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (error) {
      logError('ouverture lien externe échouée', error: error);
    }
  }
}

class _ErrorRetry extends StatelessWidget {
  const _ErrorRetry({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HomeDesign.space24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54),
            ),
            const SizedBox(height: HomeDesign.space12),
            OutlinedButton(
              onPressed: onRetry,
              child: const Text(
                'Réessayer',
                style: TextStyle(color: HomeDesign.accent),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
