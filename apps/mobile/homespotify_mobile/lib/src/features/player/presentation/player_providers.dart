import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/homespotify_audio_handler.dart';

/// Piste courante (métadonnées) diffusée par le handler audio.
/// Nommé pour le [LoggingProviderObserver] (changement de piste loggé).
final mediaItemProvider = StreamProvider<MediaItem?>(name: 'mediaItem', (ref) {
  return ref.watch(audioHandlerProvider).mediaItem;
});

/// État de lecture (play/pause, processing, position d'événement).
/// Nommé pour le [LoggingProviderObserver] (play/pause/état loggés).
final playbackStateProvider = StreamProvider<PlaybackState>(
  name: 'playbackState',
  (ref) {
    return ref.watch(audioHandlerProvider).playbackState;
  },
);

/// File de lecture exposée par audio_service pour l'UI et les contrôles système.
final queueProvider = StreamProvider<List<MediaItem>>((ref) {
  return ref.watch(audioHandlerProvider).queue;
});

/// Position continue + tampon + durée, pour la barre de progression.
final positionDataProvider = StreamProvider<PlayerPositionData>((ref) {
  return ref.watch(audioHandlerProvider).positionDataStream;
});

/// Volume interne du lecteur (0.0–1.0), pour le slider de volume.
final volumeProvider = StreamProvider<double>((ref) {
  return ref.watch(audioHandlerProvider).volumeStream;
});
