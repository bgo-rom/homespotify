import 'package:audio_service/audio_service.dart';

/// Configuration du service média Android.
///
/// Le service reste au premier plan pendant une pause afin qu'Android ne
/// bloque pas sa reprise lorsque HomeSpotify est en arrière-plan. Il est
/// réellement arrêté par l'action explicite [AudioHandler.stop].
const homeSpotifyAudioServiceConfig = AudioServiceConfig(
  androidNotificationChannelId: 'com.homespotify.mobile.audio',
  androidNotificationChannelName: 'Lecture HomeSpotify',
  androidNotificationChannelDescription:
      'Contrôles de lecture et état de la musique en cours',
  androidNotificationClickStartsActivity: true,
  androidStopForegroundOnPause: false,
);
