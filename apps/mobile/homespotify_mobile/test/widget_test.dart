import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:homespotify_mobile/src/features/player/audio/homespotify_audio_handler.dart';
import 'package:homespotify_mobile/src/features/player/presentation/player_providers.dart';
import 'package:homespotify_mobile/src/features/player/presentation/player_screen.dart';

void main() {
  testWidgets('état vide : affiche le placeholder sans piste', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mediaItemProvider.overrideWith(
            (ref) => const Stream<MediaItem?>.empty(),
          ),
          playbackStateProvider.overrideWith(
            (ref) => const Stream<PlaybackState>.empty(),
          ),
          positionDataProvider.overrideWith(
            (ref) => const Stream<PlayerPositionData>.empty(),
          ),
        ],
        child: const MaterialApp(home: PlayerScreen()),
      ),
    );

    expect(find.text('Aucune piste en lecture'), findsOneWidget);
    expect(find.text('EN LECTURE'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
  });

  testWidgets('piste chargée : affiche titre, artiste et temps', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mediaItemProvider.overrideWith(
            (ref) => Stream.value(
              const MediaItem(id: '1', title: 'Genesis', artist: 'Justice'),
            ),
          ),
          playbackStateProvider.overrideWith(
            (ref) => Stream.value(PlaybackState(playing: true)),
          ),
          positionDataProvider.overrideWith(
            (ref) => Stream.value(
              const PlayerPositionData(
                position: Duration(seconds: 30),
                bufferedPosition: Duration(seconds: 40),
                duration: Duration(minutes: 3),
              ),
            ),
          ),
        ],
        child: const MaterialApp(home: PlayerScreen()),
      ),
    );
    await tester.pump(); // laisse les Stream.value se propager

    expect(find.text('Genesis'), findsOneWidget);
    expect(find.text('Justice'), findsOneWidget);
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    expect(find.text('0:30'), findsOneWidget);
    expect(find.text('3:00'), findsOneWidget);
  });
}
