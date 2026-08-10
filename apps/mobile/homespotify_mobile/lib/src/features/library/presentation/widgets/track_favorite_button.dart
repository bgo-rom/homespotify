import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../core/theme/app_colors.dart';
import '../library_favorites.dart';

class TrackFavoriteButton extends ConsumerWidget {
  const TrackFavoriteButton({
    super.key,
    required this.trackId,
    this.iconSize = 24,
    this.visualDensity,
  });

  final int? trackId;
  final double iconSize;
  final VisualDensity? visualDensity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = trackId;
    final isReady = ref.watch(
      favoriteTrackIdsProvider.select((value) => value.asData != null),
    );
    final isFavorite = id != null && ref.watch(isFavoriteProvider(id));
    final colors = context.colors;

    return IconButton(
      tooltip: isFavorite ? 'Retirer des favoris' : 'Ajouter aux favoris',
      onPressed: id != null && isReady
          ? () => toggleFavoriteWithFeedback(context, ref, id)
          : null,
      iconSize: iconSize,
      visualDensity: visualDensity,
      color: colors.accent,
      disabledColor: colors.textTertiary,
      icon: AnimatedSwitcher(
        duration: const Duration(milliseconds: 160),
        transitionBuilder: (child, animation) =>
            ScaleTransition(scale: animation, child: child),
        child: Icon(
          isFavorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          key: ValueKey<bool>(isFavorite),
        ),
      ),
    );
  }
}

Future<void> toggleFavoriteWithFeedback(
  BuildContext context,
  WidgetRef ref,
  int trackId,
) async {
  final wasFavorite = ref.read(isFavoriteProvider(trackId));
  logUi(
    'tap favori: trackId=$trackId '
    'action=${wasFavorite ? 'retrait' : 'ajout'}',
  );
  try {
    await ref.read(favoriteTrackIdsProvider.notifier).toggle(trackId);
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Impossible d’enregistrer ce favori.')),
    );
  }
}
