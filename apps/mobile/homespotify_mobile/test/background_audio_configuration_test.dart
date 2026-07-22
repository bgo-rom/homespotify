import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:homespotify_mobile/src/features/player/audio/background_audio_config.dart';

void main() {
  test('le service média reste au premier plan pendant une pause', () {
    expect(
      homeSpotifyAudioServiceConfig.androidNotificationChannelId,
      'com.homespotify.mobile.audio',
    );
    expect(
      homeSpotifyAudioServiceConfig.androidNotificationChannelName,
      'Lecture HomeSpotify',
    );
    expect(homeSpotifyAudioServiceConfig.androidStopForegroundOnPause, isFalse);
    expect(
      homeSpotifyAudioServiceConfig.androidNotificationClickStartsActivity,
      isTrue,
    );
  });

  test('le manifeste Android déclare le service et les boutons média', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    expect(
      manifest,
      contains('android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK'),
    );
    expect(manifest, contains('android.permission.POST_NOTIFICATIONS'));
    expect(manifest, contains('com.ryanheise.audioservice.AudioService'));
    expect(
      manifest,
      contains('com.ryanheise.audioservice.MediaButtonReceiver'),
    );
    expect(manifest, contains('android.intent.action.MEDIA_BUTTON'));
  });

  test('les icônes média sont conservées dans le build release', () {
    final keepRules = File(
      'android/app/src/main/res/raw/keep.xml',
    ).readAsStringSync();

    expect(keepRules, contains('@drawable/audio_service_*'));
  });

  test('audio_service est initialisé avant le rendu de l’application', () {
    final mainSource = File('lib/main.dart').readAsStringSync();
    final serviceInitialization = mainSource.indexOf(
      'await AudioService.init<HomeSpotifyAudioHandler>',
    );
    final appRendering = mainSource.indexOf('runApp(');

    expect(serviceInitialization, greaterThanOrEqualTo(0));
    expect(appRendering, greaterThan(serviceInitialization));
    expect(mainSource, isNot(contains('_attachAndroidAudioService')));
  });
}
