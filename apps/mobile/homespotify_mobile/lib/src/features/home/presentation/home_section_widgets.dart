import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/authenticated_network_image.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/home_design.dart';
import '../../library/data/library_api.dart';
import '../../library/domain/track.dart';

/// Hauteur d'un carrousel de l'accueil : pochette carrée + deux lignes.
const double kHomeCarouselHeight = 208;
const double kHomeCardWidth = 148;

/// En-tête d'une section, avec action facultative « Tout voir ».
class HomeSectionHeader extends StatelessWidget {
  const HomeSectionHeader({
    super.key,
    required this.title,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HomeDesign.space16,
        HomeDesign.space24,
        HomeDesign.space8,
        HomeDesign.space12,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 19,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
              ),
            ),
          ),
          if (actionLabel != null && onAction != null)
            TextButton(
              onPressed: onAction,
              child: Text(
                actionLabel!,
                // Même équivalent que `SectionHeader` (Direction 33) pour la
                // même action « Tout voir » : lien discret, pas l'accent.
                style: TextStyle(
                  color: context.colors.link,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Carrousel horizontal générique.
///
/// Rend `SizedBox.shrink()` quand il n'y a rien : une section vide ne doit
/// jamais occuper d'espace ni afficher un titre orphelin.
class HomeCarousel extends StatelessWidget {
  const HomeCarousel({
    super.key,
    required this.title,
    required this.itemCount,
    required this.itemBuilder,
    this.actionLabel,
    this.onAction,
    this.height = kHomeCarouselHeight,
  });

  final String title;
  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final String? actionLabel;
  final VoidCallback? onAction;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (itemCount == 0) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HomeSectionHeader(
          title: title,
          actionLabel: actionLabel,
          onAction: onAction,
        ),
        SizedBox(
          height: height,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: HomeDesign.space16),
            itemCount: itemCount,
            separatorBuilder: (_, _) =>
                const SizedBox(width: HomeDesign.space12),
            itemBuilder: itemBuilder,
          ),
        ),
      ],
    );
  }
}

/// Vignette carrée d'une piste, d'un album ou d'un artiste.
class HomeMediaCard extends ConsumerWidget {
  const HomeMediaCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.coverTrackId,
    required this.onTap,
    this.rounded = false,
    this.badge,
    this.width = kHomeCardWidth,
  });

  final String title;
  final String subtitle;

  /// Piste dont la pochette illustre la carte ; `null` = pas de visuel.
  final int? coverTrackId;
  final VoidCallback onTap;

  /// Pochette ronde pour les artistes, carrée pour le reste.
  final bool rounded;
  final Widget? badge;
  final double width;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trackId = coverTrackId;
    final coverUrl = trackId == null
        ? null
        : ref.watch(libraryApiProvider).coverUri(trackId).toString();

    return SizedBox(
      width: width,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(HomeDesign.radiusMedium),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(
                    rounded ? width / 2 : HomeDesign.radiusMedium,
                  ),
                  child: SizedBox(
                    width: width,
                    height: width,
                    child: coverUrl == null
                        ? ColoredBox(
                            color: context.colors.surfaceSunken,
                            child: const Icon(
                              Icons.music_note_rounded,
                              color: Colors.white24,
                              size: 34,
                            ),
                          )
                        : AuthenticatedNetworkImage(
                            coverUrl,
                            fit: BoxFit.cover,
                          ),
                  ),
                ),
                if (badge != null) Positioned(right: 6, top: 6, child: badge!),
              ],
            ),
            const SizedBox(height: HomeDesign.space8),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: rounded ? TextAlign.center : TextAlign.start,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (subtitle.isNotEmpty)
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: rounded ? TextAlign.center : TextAlign.start,
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
          ],
        ),
      ),
    );
  }
}

/// Carte d'une piste jouable, avec état de chargement pendant l'ouverture.
class HomeTrackCard extends StatelessWidget {
  const HomeTrackCard({
    super.key,
    required this.track,
    required this.onTap,
    this.loading = false,
  });

  final Track track;
  final VoidCallback onTap;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return HomeMediaCard(
      title: track.title,
      subtitle: track.artist,
      coverTrackId: track.hasCover ? track.id : null,
      onTap: loading ? () {} : onTap,
      badge: loading
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: context.colors.accent,
              ),
            )
          : null,
    );
  }
}
