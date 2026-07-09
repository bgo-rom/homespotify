import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:homespotify_mobile/src/features/player/audio/homespotify_audio_handler.dart';
import 'package:homespotify_mobile/src/features/player/presentation/player_providers.dart';
import 'package:homespotify_mobile/src/features/player/presentation/player_screen.dart';

void main() {
  // Surface de test type téléphone : la colonne du lecteur (pochette + contrôles
  // + volume) dépasse les 600px par défaut.
  Future<void> usePhoneSurface(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  testWidgets('état vide : affiche le placeholder sans piste', (tester) async {
    await usePhoneSurface(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mediaItemProvider.overrideWith(
            (ref) => const Stream<MediaItem?>.empty(),
          ),
          playbackStateProvider.overrideWith(
            (ref) => const Stream<PlaybackState>.empty(),
          ),
          queueProvider.overrideWith(
            (ref) => Stream.value(const <MediaItem>[]),
          ),
          positionDataProvider.overrideWith(
            (ref) => const Stream<PlayerPositionData>.empty(),
          ),
          volumeProvider.overrideWith((ref) => Stream.value(1.0)),
        ],
        child: const MaterialApp(home: PlayerScreen()),
      ),
    );

    expect(find.text('Aucune piste en lecture'), findsOneWidget);
    expect(find.text('EN LECTURE'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.skip_previous_rounded),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.skip_next_rounded),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('piste chargée : affiche titre, artiste, temps et volume', (
    tester,
  ) async {
    await usePhoneSurface(tester);
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
          queueProvider.overrideWith(
            (ref) => Stream.value(const <MediaItem>[
              MediaItem(id: '1', title: 'Genesis', artist: 'Justice'),
            ]),
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
          volumeProvider.overrideWith((ref) => Stream.value(0.8)),
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
    // 2 sliders : progression (SeekBar) + volume ; l'icône volume est unique.
    expect(find.byType(Slider), findsNWidgets(2));
    expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);
    expect(find.text('80 %'), findsOneWidget);
  });

  testWidgets('buffering : affiche preparation et bloque le play initial', (
    tester,
  ) async {
    await usePhoneSurface(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mediaItemProvider.overrideWith(
            (ref) => Stream.value(
              const MediaItem(id: '1', title: 'Genesis', artist: 'Justice'),
            ),
          ),
          playbackStateProvider.overrideWith(
            (ref) => Stream.value(
              PlaybackState(
                playing: false,
                processingState: AudioProcessingState.buffering,
              ),
            ),
          ),
          queueProvider.overrideWith(
            (ref) => Stream.value(const <MediaItem>[
              MediaItem(id: '1', title: 'Genesis', artist: 'Justice'),
            ]),
          ),
          positionDataProvider.overrideWith(
            (ref) => Stream.value(PlayerPositionData.zero),
          ),
          volumeProvider.overrideWith((ref) => Stream.value(1.0)),
        ],
        child: const MaterialApp(home: PlayerScreen()),
      ),
    );
    await tester.pump();

    final preparationLabel = find.text('Preparation de la lecture...');
    final bufferingLabel = find.text('Mise en tampon audio...');
    expect(
      preparationLabel.evaluate().isNotEmpty ||
          bufferingLabel.evaluate().isNotEmpty,
      isTrue,
    );
    expect(find.byType(CircularProgressIndicator), findsWidgets);
  });

  testWidgets('queue : précédent/suivant suivent les bornes de la file', (
    tester,
  ) async {
    await usePhoneSurface(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mediaItemProvider.overrideWith(
            (ref) => Stream.value(
              const MediaItem(id: '1', title: 'Genesis', artist: 'Justice'),
            ),
          ),
          playbackStateProvider.overrideWith(
            (ref) => Stream.value(
              PlaybackState(
                playing: true,
                processingState: AudioProcessingState.ready,
                queueIndex: 0,
              ),
            ),
          ),
          queueProvider.overrideWith(
            (ref) => Stream.value(const <MediaItem>[
              MediaItem(id: '1', title: 'Genesis', artist: 'Justice'),
              MediaItem(id: '2', title: 'Stress', artist: 'Justice'),
            ]),
          ),
          positionDataProvider.overrideWith(
            (ref) => Stream.value(PlayerPositionData.zero),
          ),
          volumeProvider.overrideWith((ref) => Stream.value(1.0)),
        ],
        child: const MaterialApp(home: PlayerScreen()),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.skip_previous_rounded), findsOneWidget);
    expect(find.byIcon(Icons.skip_next_rounded), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.skip_previous_rounded),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.skip_next_rounded),
          )
          .onPressed,
      isNotNull,
    );
  });
}
