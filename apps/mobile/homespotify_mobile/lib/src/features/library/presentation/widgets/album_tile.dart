import 'package:flutter/material.dart';

import '../../../../core/network/authenticated_network_image.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_shapes.dart';

import '../library_albums.dart';

/// Carte d'album (grille des albums) : pochette sculptée, titre, artiste, méta.
class AlbumTile extends StatelessWidget {
  const AlbumTile({
    super.key,
    required this.album,
    required this.coverUrl,
    required this.onTap,
  });

  final AlbumSummary album;
  final String? coverUrl;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.artworkRadius,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: AppRadius.artworkRadius,
                boxShadow: colors.clayShadow,
              ),
              child: AlbumCover(url: coverUrl, borderRadius: AppRadius.artwork),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            album.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              fontSize: 14.5,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            album.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 12,
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${album.trackCount} '
            '${album.trackCount > 1 ? 'pistes' : 'piste'} · '
            '${formatAlbumDuration(album.totalDuration)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 10.5,
              color: colors.textTertiary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Pochette carrée avec placeholder sculpté.
class AlbumCover extends StatelessWidget {
  const AlbumCover({super.key, required this.url, this.borderRadius = 20});

  final String? url;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: AspectRatio(
        aspectRatio: 1,
        child: url == null
            ? const _CoverPlaceholder()
            : AuthenticatedNetworkImage(
                url!,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.low,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => const _CoverPlaceholder(),
                loadingBuilder: (context, child, progress) =>
                    progress == null ? child : const _CoverPlaceholder(),
              ),
      ),
    );
  }
}

class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ColoredBox(
      color: colors.surfaceSunken,
      child: Center(
        child: Icon(Icons.album_rounded, color: colors.textTertiary, size: 40),
      ),
    );
  }
}
