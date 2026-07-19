import 'package:flutter/material.dart';

import '../../../../core/network/authenticated_network_image.dart';

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
    final trackLabel = artist.trackCount > 1 ? 'pistes' : 'piste';
    final albumLabel = artist.albumCount > 1 ? 'albums' : 'album';
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: SizedBox(
        width: 64,
        height: 64,
        child: ArtistArtwork(url: coverUrl, cacheSize: 128),
      ),
      title: Text(
        artist.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 15.5,
          fontWeight: FontWeight.w700,
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
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ),
      trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white38),
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
    return ClipRRect(borderRadius: BorderRadius.circular(12), child: image);
  }
}

class _ArtistPlaceholder extends StatelessWidget {
  const _ArtistPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0xFF282832),
      child: Center(
        child: Icon(Icons.person_rounded, color: Colors.white24, size: 34),
      ),
    );
  }
}
