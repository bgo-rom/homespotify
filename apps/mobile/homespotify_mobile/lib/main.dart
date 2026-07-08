import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/app/router.dart';
import 'src/features/player/audio/homespotify_audio_handler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final audioHandler = await AudioService.init<HomeSpotifyAudioHandler>(
    builder: HomeSpotifyAudioHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.homespotify.mobile.audio',
      androidNotificationChannelName: 'HomeSpotify playback',
      androidNotificationOngoing: true,
    ),
  );

  runApp(
    ProviderScope(
      overrides: [audioHandlerProvider.overrideWithValue(audioHandler)],
      child: const HomeSpotifyMobileApp(),
    ),
  );
}

class HomeSpotifyMobileApp extends StatelessWidget {
  const HomeSpotifyMobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'HomeSpotify',
      debugShowCheckedModeBanner: false,
      routerConfig: appRouter,
    );
  }
}
