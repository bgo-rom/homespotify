import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/authenticated_network_image.dart';
import '../../../../core/theme/home_design.dart';
import '../../domain/track.dart';
import 'current_track_indicator.dart';
import 'track_favorite_button.dart';

class LibraryTrackTile extends ConsumerWidget {
  const LibraryTrackTile({
    super.key,
    required this.track,
    required this.coverUrl,
    required this.isLoading,
    required this.onTap,
    required this.onLongPress,
  });

  final Track track;
  final String? coverUrl;
  final bool isLoading;
  final VoidCallback? onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(isTrackPlayingProvider('${track.id}'));
    final secondary = [
      track.artist,
      if (track.album.isNotEmpty) track.album,
    ].join(' · ');
    final details = <String>[
      if (track.formatLabel != null) track.formatLabel!,
      if (track.duration != null) _formatDuration(track.duration!),
      if (track.quality?.shortLabel != null) track.quality!.shortLabel!,
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(HomeDesign.radiusMedium),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey<int>(track.id),
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(HomeDesign.radiusMedium),
          child: Semantics(
            button: true,
            label: 'Lire ${track.title} de ${track.artist}',
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 76),
              child: Row(
                children: [
                  AnimatedContainer(
                    duration: HomeDesign.animationDuration(
                      context,
                      HomeDesign.microAnimation,
                    ),
                    width: 3,
                    height: active ? 44 : 20,
                    decoration: BoxDecoration(
                      color: active ? HomeDesign.accent : Colors.transparent,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(width: 9),
                  _TrackArtwork(url: coverUrl, active: active),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AnimatedDefaultTextStyle(
                          duration: HomeDesign.animationDuration(
                            context,
                            HomeDesign.microAnimation,
                          ),
                          style: TextStyle(
                            color: active ? HomeDesign.accent : Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                          child: Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          isLoading ? 'Préparation de la lecture…' : secondary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isLoading
                                ? HomeDesign.accent
                                : Colors.white54,
                            fontSize: 12.5,
                          ),
                        ),
                        if (details.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            details,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white30,
                              fontSize: 10.5,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (isLoading)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          color: HomeDesign.accent,
                        ),
                      ),
                    )
                  else ...[
                    CurrentTrackIndicator(trackId: '${track.id}'),
                    TrackFavoriteButton(
                      trackId: track.id,
                      iconSize: 22,
                      visualDensity: VisualDensity.compact,
                    ),
                    IconButton(
                      tooltip: 'Actions pour ${track.title}',
                      onPressed: onLongPress,
                      icon: const Icon(
                        Icons.more_vert_rounded,
                        color: Colors.white54,
                      ),
                    ),
                  ],
                  const SizedBox(width: 2),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TrackArtwork extends StatelessWidget {
  const _TrackArtwork({required this.url, required this.active});

  final String? url;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final placeholder = const ColoredBox(
      color: HomeDesign.surfaceRaised,
      child: Icon(Icons.music_note_rounded, color: Colors.white24, size: 24),
    );
    return AnimatedScale(
      scale: active ? 1.04 : 1,
      duration: HomeDesign.animationDuration(
        context,
        HomeDesign.microAnimation,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(HomeDesign.radiusSmall),
        child: SizedBox(
          width: 54,
          height: 54,
          child: url == null
              ? placeholder
              : AuthenticatedNetworkImage(
                  url!,
                  fit: BoxFit.cover,
                  cacheWidth: 108,
                  cacheHeight: 108,
                  filterQuality: FilterQuality.low,
                  gaplessPlayback: true,
                  loadingBuilder: (context, child, progress) =>
                      progress == null ? child : placeholder,
                  errorBuilder: (_, _, _) => placeholder,
                ),
        ),
      ),
    );
  }
}

String _formatDuration(Duration duration) {
  final minutes = duration.inMinutes;
  final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
