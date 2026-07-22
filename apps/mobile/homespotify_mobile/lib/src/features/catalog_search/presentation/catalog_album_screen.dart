import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/theme/home_design.dart';
import '../../library/data/library_api.dart';
import '../data/catalog_search_api.dart';
import '../domain/catalog_models.dart';
import 'catalog_preview_controller.dart';
import 'request_from_catalog_sheet.dart';

final catalogAlbumProvider = FutureProvider.autoDispose
    .family<CatalogAlbumDetail, CatalogEntityRef>((ref, reference) {
      return ref.watch(catalogSearchApiProvider).fetchAlbum(reference);
    });

String _formatDuration(int? durationMs) {
  if (durationMs == null || durationMs <= 0) return '';
  final total = Duration(milliseconds: durationMs);
  final minutes = total.inMinutes;
  final seconds = total.inSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

/// Fiche album catalogue : tracklist ordonnée, badges bibliothèque, preview
/// par piste et demande d'album complète (snapshot ordonné).
class CatalogAlbumScreen extends ConsumerWidget {
  const CatalogAlbumScreen({
    super.key,
    required this.provider,
    required this.albumId,
  });

  final String provider;
  final String albumId;

  CatalogEntityRef get _reference => CatalogEntityRef(
    provider: provider,
    entityType: CatalogEntityType.album,
    externalId: albumId,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final album = ref.watch(catalogAlbumProvider(_reference));
    return Scaffold(
      backgroundColor: HomeDesign.background,
      appBar: AppBar(
        backgroundColor: HomeDesign.background,
        foregroundColor: Colors.white,
        title: Text(
          album.asData?.value.title ?? 'Album',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: album.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: HomeDesign.accent),
        ),
        error: (error, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                error.toString(),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54),
              ),
              const SizedBox(height: HomeDesign.space12),
              OutlinedButton(
                onPressed: () =>
                    ref.invalidate(catalogAlbumProvider(_reference)),
                child: const Text(
                  'Réessayer',
                  style: TextStyle(color: HomeDesign.accent),
                ),
              ),
            ],
          ),
        ),
        data: (detail) => _AlbumContent(detail: detail),
      ),
    );
  }
}

class _AlbumContent extends ConsumerWidget {
  const _AlbumContent({required this.detail});

  final CatalogAlbumDetail detail;

  Set<String> _ownedTitles(WidgetRef ref) {
    final tracks = ref.watch(libraryProvider).asData?.value ?? const [];
    final identities = {
      for (final track in tracks) track.title.trim().toLowerCase(),
    };
    return {
      for (final track in detail.tracks)
        if (identities.contains(track.title.trim().toLowerCase()))
          track.title.toLowerCase(),
    };
  }

  Future<void> _requestAlbum(
    BuildContext context,
    WidgetRef ref,
    Set<String> ownedTitles,
  ) async {
    await ref.read(catalogPreviewProvider.notifier).stop();
    if (!context.mounted) return;
    final sent = await showCatalogRequestSheet(
      context,
      ref,
      CatalogRequestSheetData.fromAlbum(detail, ownedItemTitles: ownedTitles),
    );
    if (sent && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Demande d’album envoyée.'),
          action: SnackBarAction(
            label: 'Mes demandes',
            onPressed: () => context.push('/requests'),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preview = ref.watch(catalogPreviewProvider);
    final ownedTitles = _ownedTitles(ref);
    final totalDuration = detail.totalDurationMs;
    final positiveLinks = detail.links
        .where((link) => link.status.isPositive && link.url != null)
        .toList(growable: false);
    return ListView(
      key: const ValueKey('catalog-album-content'),
      padding: const EdgeInsets.all(HomeDesign.space16),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(HomeDesign.radiusMedium),
              child: SizedBox(
                width: 112,
                height: 112,
                child: detail.imageUrl == null
                    ? const ColoredBox(
                        color: HomeDesign.surfaceMuted,
                        child: Icon(
                          Icons.album_rounded,
                          color: Colors.white38,
                          size: 44,
                        ),
                      )
                    : Image.network(
                        detail.imageUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const ColoredBox(
                          color: HomeDesign.surfaceMuted,
                          child: Icon(
                            Icons.album_rounded,
                            color: Colors.white38,
                          ),
                        ),
                      ),
              ),
            ),
            const SizedBox(width: HomeDesign.space16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    detail.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    detail.artistNames.join(', '),
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: HomeDesign.space4),
                  Text(
                    [
                      if (detail.albumType != null) detail.albumType!,
                      if (detail.releaseDate != null) detail.releaseDate!,
                      if (detail.label != null) detail.label!,
                      if ((detail.discCount ?? 1) > 1)
                        '${detail.discCount} disques',
                      '${detail.tracks.length} pistes',
                      if (totalDuration > 0)
                        '${Duration(milliseconds: totalDuration).inMinutes} min',
                    ].join(' · '),
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: HomeDesign.space16),
        FilledButton.icon(
          key: const ValueKey('catalog-album-request'),
          style: FilledButton.styleFrom(
            backgroundColor: HomeDesign.accent,
            foregroundColor: Colors.black,
          ),
          onPressed: detail.tracks.isEmpty
              ? null
              : () => _requestAlbum(context, ref, ownedTitles),
          icon: const Icon(Icons.library_add_rounded),
          label: const Text('Demander l’album'),
        ),
        if (positiveLinks.isNotEmpty) ...[
          const SizedBox(height: HomeDesign.space12),
          Wrap(
            spacing: HomeDesign.space8,
            children: [
              for (final link in positiveLinks)
                ActionChip(
                  key: ValueKey('album-link-${link.platform}'),
                  backgroundColor: HomeDesign.surface,
                  avatar: const Icon(
                    Icons.open_in_new_rounded,
                    size: 14,
                    color: Colors.white54,
                  ),
                  label: Text(
                    link.platform,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  onPressed: () => _openExternal(link.url!),
                ),
            ],
          ),
        ],
        if (preview.mainPlaybackInterrupted)
          Padding(
            padding: const EdgeInsets.only(top: HomeDesign.space8),
            child: TextButton.icon(
              key: const ValueKey('album-resume-playback'),
              onPressed: () => ref
                  .read(catalogPreviewProvider.notifier)
                  .resumeMainPlayback(),
              icon: const Icon(
                Icons.play_circle_rounded,
                color: HomeDesign.accent,
              ),
              label: const Text(
                'Reprendre ma musique',
                style: TextStyle(color: HomeDesign.accent),
              ),
            ),
          ),
        const SizedBox(height: HomeDesign.space16),
        for (final track in detail.tracks)
          _AlbumTrackTile(
            track: track,
            multiDisc: (detail.discCount ?? 1) > 1,
            owned: ownedTitles.contains(track.title.toLowerCase()),
            previewState: preview,
          ),
      ],
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

class _AlbumTrackTile extends ConsumerWidget {
  const _AlbumTrackTile({
    required this.track,
    required this.multiDisc,
    required this.owned,
    required this.previewState,
  });

  final CatalogAlbumTrack track;
  final bool multiDisc;
  final bool owned;
  final CatalogPreviewState previewState;

  String get _previewKey =>
      'album-track:${track.discNumber ?? 1}:${track.position}:${track.title}';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasPreview =
        track.preview != null && !track.preview!.requiresOfficialSdk;
    final isActive = previewState.isActiveFor(_previewKey);
    final number = multiDisc
        ? '${track.discNumber ?? 1}.${track.trackNumber ?? track.position}'
        : '${track.trackNumber ?? track.position}';
    final duration = _formatDuration(track.durationMs);
    return ListTile(
      key: ValueKey('album-track-${track.position}'),
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: SizedBox(
        width: 32,
        child: Text(
          number,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white38),
        ),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white),
            ),
          ),
          if (track.explicit == true)
            const Icon(Icons.explicit_rounded, size: 14, color: Colors.white38),
        ],
      ),
      subtitle: Text(
        [
          if (track.artistNames.isNotEmpty) track.artistNames.join(', '),
          if (duration.isNotEmpty) duration,
          if (owned) 'Dans ma bibliothèque',
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: owned ? HomeDesign.accent : Colors.white54,
          fontSize: 12,
        ),
      ),
      trailing: hasPreview
          ? IconButton(
              key: ValueKey('album-track-preview-${track.position}'),
              tooltip: isActive ? 'Arrêter l’aperçu' : 'Écouter un aperçu',
              icon: Icon(
                isActive
                    ? Icons.stop_circle_rounded
                    : Icons.play_circle_outline_rounded,
                color: HomeDesign.accent,
              ),
              onPressed: () => ref
                  .read(catalogPreviewProvider.notifier)
                  .toggle(_previewKey, track.preview!),
            )
          : null,
    );
  }
}
