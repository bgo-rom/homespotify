import 'package:flutter/material.dart';

import '../../../../core/network/authenticated_network_image.dart';
import '../../../../core/theme/app_colors.dart';

import '../library_artists.dart';

class ArtistTile extends StatelessWidget {
  const ArtistTile({
    super.key,
    required this.artist,
    required this.coverUrl,
    required this.onTap,
  });

  final ArtistSummary artist;
  final String? coverUrl;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    final trackLabel = artist.trackCount > 1 ? 'pistes' : 'piste';
    final albumLabel = artist.albumCount > 1 ? 'albums' : 'album';
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      leading: SizedBox(
        width: 64,
        height: 64,
        child: ArtistArtwork(url: coverUrl, cacheSize: 128),
      ),
      title: Text(
        artist.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleMedium?.copyWith(
          color: colors.textPrimary,
        ),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 5),
        child: Text(
          '${artist.trackCount} $trackLabel · '
          '${artist.albumCount} $albumLabel · '
          '${formatArtistDuration(artist.totalDuration)}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.textSecondary,
          ),
        ),
      ),
      trailing: Icon(Icons.chevron_right_rounded, color: colors.textTertiary),
    );
  }
}

class ArtistArtwork extends StatelessWidget {
  const ArtistArtwork({
    super.key,
    required this.url,
    this.circular = true,
    this.cacheSize = 360,
  });

  final String? url;
  final bool circular;
  final int cacheSize;

  @override
  Widget build(BuildContext context) {
    final image = url == null
        ? const _ArtistPlaceholder()
        : AuthenticatedNetworkImage(
            url!,
            fit: BoxFit.cover,
            cacheWidth: cacheSize,
            cacheHeight: cacheSize,
            filterQuality: FilterQuality.low,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => const _ArtistPlaceholder(),
            loadingBuilder: (context, child, progress) =>
                progress == null ? child : const _ArtistPlaceholder(),
          );
    if (circular) return ClipOval(child: image);
    return ClipRRect(borderRadius: BorderRadius.circular(16), child: image);
  }
}

class _ArtistPlaceholder extends StatelessWidget {
  const _ArtistPlaceholder();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ColoredBox(
      color: colors.surfaceSunken,
      child: Center(
        child: Icon(Icons.person_rounded, color: colors.textTertiary, size: 34),
      ),
    );
  }
}
