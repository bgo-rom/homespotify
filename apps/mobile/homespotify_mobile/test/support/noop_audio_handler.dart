import 'package:homespotify_mobile/src/features/player/audio/homespotify_audio_handler.dart';

/// Double minimal pour les écrans qui affichent seulement le moteur audio.
/// Tout nouvel usage du lecteur dans ces tests doit être déclaré explicitement.
class NoopHomeSpotifyAudioHandler implements HomeSpotifyAudioHandler {
  @override
  String get currentTimeStretchEngineName => 'media3';

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'NoopHomeSpotifyAudioHandler ne gère pas ${invocation.memberName}',
  );
}
