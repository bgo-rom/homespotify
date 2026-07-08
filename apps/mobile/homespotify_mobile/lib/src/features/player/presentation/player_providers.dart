import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/homespotify_audio_handler.dart';

/// Piste courante (métadonnées) diffusée par le handler audio.
final mediaItemProvider = StreamProvider<MediaItem?>((ref) {
  return ref.watch(audioHandlerProvider).mediaItem;
});

/// État de lecture (play/pause, processing, position d'événement).
final playbackStateProvider = StreamProvider<PlaybackState>((ref) {
  return ref.watch(audioHandlerProvider).playbackState;
});

/// Position continue + tampon + durée, pour la barre de progression.
final positionDataProvider = StreamProvider<PlayerPositionData>((ref) {
  return ref.watch(audioHandlerProvider).positionDataStream;
});
