import 'package:flutter/material.dart';

import '../../../../core/network/authenticated_network_image.dart';

import '../library_albums.dart';

/// Carte d'album (grille des albums) : pochette, titre, artiste, méta.
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: AlbumCover(url: coverUrl, borderRadius: 10)),
          const SizedBox(height: 8),
          Text(
            album.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            album.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white54, fontSize: 11.5),
          ),
          const SizedBox(height: 2),
          Text(
            '${album.trackCount} '
            '${album.trackCount > 1 ? 'pistes' : 'piste'} · '
            '${formatAlbumDuration(album.totalDuration)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white38, fontSize: 10.5),
          ),
        ],
      ),
    );
  }
}

/// Pochette carrée avec placeholder sombre.
class AlbumCover extends StatelessWidget {
  const AlbumCover({super.key, required this.url, this.borderRadius = 10});

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
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2C2C36), Color(0xFF1A1A22)],
        ),
      ),
      child: Center(
        child: Icon(Icons.album_rounded, color: Colors.white24, size: 40),
      ),
    );
  }
}
