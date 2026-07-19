import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../player/presentation/player_providers.dart';

final currentPlayingTrackIdProvider = Provider<String?>((ref) {
  final currentTrackId = ref.watch(
    mediaItemProvider.select((value) => value.asData?.value?.id),
  );
  final playing = ref.watch(
    playbackStateProvider.select(
      (value) => value.asData?.value.playing ?? false,
    ),
  );
  return playing ? currentTrackId : null;
});

final isTrackPlayingProvider = Provider.family<bool, String>((ref, trackId) {
  return ref.watch(currentPlayingTrackIdProvider) == trackId;
});

/// Indicateur léger partagé par les listes de pistes.
///
/// Comme dans la bibliothèque, il est visible uniquement pendant la lecture.
class CurrentTrackIndicator extends ConsumerWidget {
  const CurrentTrackIndicator({super.key, required this.trackId});

  final String trackId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playing = ref.watch(isTrackPlayingProvider(trackId));
    if (!playing) {
      return const SizedBox.shrink();
    }
    return Tooltip(
      key: ValueKey<String>('current-track-indicator-$trackId'),
      message: 'En lecture',
      child: const SizedBox(
        width: 20,
        height: 20,
        child: Icon(
          Icons.graphic_eq_rounded,
          color: Color(0xFF1DB954),
          size: 18,
        ),
      ),
    );
  }
}
