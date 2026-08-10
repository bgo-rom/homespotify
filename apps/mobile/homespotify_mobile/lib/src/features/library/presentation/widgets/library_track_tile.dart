import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/authenticated_network_image.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_shapes.dart';
import '../../../../core/theme/home_design.dart';
import '../../../offline/application/offline_index.dart';
import '../../domain/track.dart';
import 'current_track_indicator.dart';
import 'track_favorite_button.dart';

/// Ligne de piste « Direction 33 ». Toutes les couleurs viennent de
/// `context.colors` ; la logique (favori, indicateur de lecture, badge hors
/// ligne, détails techniques, état de chargement) est inchangée.
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
    final colors = context.colors;
    final theme = Theme.of(context);
    final active = ref.watch(isTrackPlayingProvider('${track.id}'));
    // Badge hors ligne : lu depuis l'index mémoire partagé (une seule lecture
    // SQLite par session, jamais une requête par piste).
    final offlineProfile = ref.watch(offlineProfileLabelProvider(track.id));
    final localCoverUrl = ref.watch(offlineCoverUrlProvider(track.id));
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
        color: active ? colors.accentSoft : Colors.transparent,
        borderRadius: AppRadius.cardRadius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey<int>(track.id),
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: AppRadius.cardRadius,
          child: Semantics(
            button: true,
            label: 'Lire ${track.title} de ${track.artist}',
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 76),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
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
                        color: active ? colors.accent : Colors.transparent,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(width: 9),
                    _TrackArtwork(url: localCoverUrl ?? coverUrl, active: active),
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
                            style: (theme.textTheme.titleMedium ??
                                    const TextStyle())
                                .copyWith(
                              color: active
                                  ? colors.accent
                                  : colors.textPrimary,
                            ),
                            child: Text(
                              track.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            isLoading
                                ? 'Préparation de la lecture…'
                                : secondary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: isLoading
                                  ? colors.accent
                                  : colors.textSecondary,
                            ),
                          ),
                          if (details.isNotEmpty ||
                              offlineProfile != null) ...[
                            const SizedBox(height: 3),
                            Row(
                              children: [
                                if (offlineProfile != null) ...[
                                  Icon(
                                    Icons.download_done_rounded,
                                    key: ValueKey('offline-badge-${track.id}'),
                                    size: 12,
                                    color: colors.accent,
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    offlineProfile,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: colors.accent,
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  if (details.isNotEmpty)
                                    Text(
                                      ' · ',
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(
                                        color: colors.textTertiary,
                                        fontSize: 10.5,
                                      ),
                                    ),
                                ],
                                Flexible(
                                  child: Text(
                                    details,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: colors.textTertiary,
                                      fontSize: 10.5,
                                      fontFeatures: const [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (isLoading)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: colors.accent,
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
                        icon: Icon(
                          Icons.more_vert_rounded,
                          color: colors.textSecondary,
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
    final colors = context.colors;
    final placeholder = ColoredBox(
      color: colors.surfaceSunken,
      child: Icon(
        Icons.music_note_rounded,
        color: colors.textTertiary,
        size: 24,
      ),
    );
    return AnimatedScale(
      scale: active ? 1.04 : 1,
      duration: HomeDesign.animationDuration(
        context,
        HomeDesign.microAnimation,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.chip),
          boxShadow: colors.clayShadowSmall,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.chip),
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
      ),
    );
  }
}

String _formatDuration(Duration duration) {
  final minutes = duration.inMinutes;
  final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
