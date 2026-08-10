import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:homespotify_mobile/src/features/player/audio/homespotify_audio_handler.dart';
import 'package:homespotify_mobile/src/features/library/application/track_library_membership.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_favorites.dart';
import 'package:homespotify_mobile/src/features/player/presentation/player_providers.dart';
import 'package:homespotify_mobile/src/features/player/presentation/player_screen.dart';

import 'support/fake_library_repositories.dart';

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
          favoritesApiProvider.overrideWithValue(FakeFavoritesRepository()),
          // Le menu du lecteur lit l'appartenance serveur : sans override, un
          // vrai GET Dio partirait et laisserait un timer en attente.
          remoteTrackMembershipProvider.overrideWith(
            (ref, trackId) async => true,
          ),
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
          favoritesApiProvider.overrideWithValue(FakeFavoritesRepository()),
          // Le menu du lecteur lit l'appartenance serveur : sans override, un
          // vrai GET Dio partirait et laisserait un timer en attente.
          remoteTrackMembershipProvider.overrideWith(
            (ref, trackId) async => true,
          ),
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
    expect(find.text('-2:30'), findsOneWidget);
    // 2 sliders : progression (SeekBar) + volume ; l'icône volume est unique.
    expect(find.byType(Slider), findsNWidgets(2));
    expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);
    expect(find.text('80 %'), findsOneWidget);
  });

  testWidgets(
    'mise en tampon transitoire : aucun clignotement de l’indicateur',
    (tester) async {
      final states = StreamController<PlaybackState>.broadcast();
      addTearDown(states.close);
      await usePhoneSurface(tester);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            favoritesApiProvider.overrideWithValue(FakeFavoritesRepository()),
            remoteTrackMembershipProvider.overrideWith(
              (ref, trackId) async => true,
            ),
            mediaItemProvider.overrideWith(
              (ref) => Stream.value(
                const MediaItem(id: '1', title: 'Genesis', artist: 'Justice'),
              ),
            ),
            playbackStateProvider.overrideWith((ref) => states.stream),
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

      states.add(
        PlaybackState(
          playing: true,
          processingState: AudioProcessingState.ready,
        ),
      );
      await tester.pump();

      // Rebuffer réseau bref (150 ms) : sous le seuil d'affichage.
      states.add(
        PlaybackState(
          playing: true,
          processingState: AudioProcessingState.buffering,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      states.add(
        PlaybackState(
          playing: true,
          processingState: AudioProcessingState.ready,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        find.text('Mise en tampon audio...'),
        findsNothing,
        reason: 'un rebuffer de 150 ms ne doit rien afficher',
      );
      expect(find.text('Preparation de la lecture...'), findsNothing);
    },
  );

  testWidgets('buffering : affiche preparation et bloque le play initial', (
    tester,
  ) async {
    await usePhoneSurface(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          favoritesApiProvider.overrideWithValue(FakeFavoritesRepository()),
          // Le menu du lecteur lit l'appartenance serveur : sans override, un
          // vrai GET Dio partirait et laisserait un timer en attente.
          remoteTrackMembershipProvider.overrideWith(
            (ref, trackId) async => true,
          ),
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

    // L'indicateur est volontairement retardé : une mise en tampon de
    // quelques dizaines de ms ne doit pas faire clignoter le Player.
    expect(
      preparationLabel.evaluate().isEmpty && bufferingLabel.evaluate().isEmpty,
      isTrue,
      reason: 'aucun indicateur avant le délai anti-clignotement',
    );

    // Mise en tampon durable : le message doit bien finir par apparaître.
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      preparationLabel.evaluate().isNotEmpty ||
          bufferingLabel.evaluate().isNotEmpty,
      isTrue,
    );
    expect(find.byType(CircularProgressIndicator), findsWidgets);
  });

  // Overrides d'une piste en lecture, réutilisés par les tests de taille.
  loadedOverrides() => [
    favoritesApiProvider.overrideWithValue(FakeFavoritesRepository()),
    // Le menu du lecteur lit l'appartenance serveur : sans override, un
    // vrai GET Dio partirait et laisserait un timer en attente.
    remoteTrackMembershipProvider.overrideWith((ref, trackId) async => true),
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
  ];

  Future<void> pumpAtSize(WidgetTester tester, Size size) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: loadedOverrides(),
        child: const MaterialApp(home: PlayerScreen()),
      ),
    );
    await tester.pump();
  }

  testWidgets('petit écran portrait : aucun overflow, contrôles présents', (
    tester,
  ) async {
    await pumpAtSize(tester, const Size(320, 480));

    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    expect(find.byIcon(Icons.replay_10_rounded), findsOneWidget);
    expect(find.byIcon(Icons.forward_10_rounded), findsOneWidget);
  });

  testWidgets('hauteur réduite (paysage) : aucun overflow, contenu défilant', (
    tester,
  ) async {
    await pumpAtSize(tester, const Size(640, 300));

    expect(tester.takeException(), isNull);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
  });

  testWidgets('écran moyen : pochette réduite sans overflow', (tester) async {
    await pumpAtSize(tester, const Size(400, 560));

    expect(tester.takeException(), isNull);
    // Branche avec pochette adaptative (pas de scroll nécessaire).
    expect(find.byType(SingleChildScrollView), findsNothing);
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
  });

  testWidgets('queue : précédent/suivant suivent les bornes de la file', (
    tester,
  ) async {
    await usePhoneSurface(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          favoritesApiProvider.overrideWithValue(FakeFavoritesRepository()),
          // Le menu du lecteur lit l'appartenance serveur : sans override, un
          // vrai GET Dio partirait et laisserait un timer en attente.
          remoteTrackMembershipProvider.overrideWith(
            (ref, trackId) async => true,
          ),
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
