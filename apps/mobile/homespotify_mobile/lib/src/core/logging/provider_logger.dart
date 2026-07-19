import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_logger.dart';

/// Observe les providers **nommés** importants (piste courante, état de
/// lecture, recherche, tri). Les providers non nommés — dont la position
/// audio et le volume — sont ignorés : aucun spam de ticks.
final class LoggingProviderObserver extends ProviderObserver {
  const LoggingProviderObserver();

  @override
  void didUpdateProvider(
    ProviderObserverContext context,
    Object? previousValue,
    Object? newValue,
  ) {
    final name = context.provider.name;
    if (name == null) return;

    switch (name) {
      case 'mediaItem':
        final prev = _unwrap(previousValue);
        final next = _unwrap(newValue);
        if (next is MediaItem && (prev is! MediaItem || prev.id != next.id)) {
          logAudioAction(
            'piste courante: "${next.title}" (id=${next.id}, '
            'album=${next.album ?? 'inconnu'})',
          );
        }
      case 'playbackState':
        final prev = _unwrap(previousValue);
        final next = _unwrap(newValue);
        if (next is PlaybackState) {
          final old = prev is PlaybackState ? prev : null;
          // Seulement play/pause et changements d'état — pas la position.
          if (old == null ||
              old.playing != next.playing ||
              old.processingState != next.processingState) {
            logAudioAction(
              'état lecture: playing=${next.playing} '
              'state=${next.processingState.name}'
              '${next.errorMessage != null ? ' erreur="${next.errorMessage}"' : ''}',
            );
          }
        }
      case 'librarySearchQuery':
        logLibrary('recherche: "$newValue"');
      case 'librarySort':
        logLibrary('tri: $newValue');
    }
  }

  Object? _unwrap(Object? value) =>
      value is AsyncValue<Object?> ? value.asData?.value : value;
}
