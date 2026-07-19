import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:homespotify_mobile/src/features/player/audio/homespotify_audio_handler.dart';
import 'package:homespotify_mobile/src/features/player/presentation/player_providers.dart';
import 'package:homespotify_mobile/src/features/player/presentation/player_screen.dart';

const Color _accent = Color(0xFF1DB954);

void main() {
  Future<void> pumpPlayer(
    WidgetTester tester, {
    required _FakeAudioHandler handler,
    AudioServiceShuffleMode shuffleMode = AudioServiceShuffleMode.none,
    AudioServiceRepeatMode repeatMode = AudioServiceRepeatMode.none,
    int queueLength = 2,
    int queueIndex = 0,
  }) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final queue = List<MediaItem>.generate(
      queueLength,
      (i) => MediaItem(id: '${i + 1}', title: 'Piste ${i + 1}'),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          audioHandlerProvider.overrideWithValue(handler),
          mediaItemProvider.overrideWith(
            (ref) => Stream.value(queue[queueIndex]),
          ),
          playbackStateProvider.overrideWith(
            (ref) => Stream.value(
              PlaybackState(
                playing: true,
                processingState: AudioProcessingState.ready,
                queueIndex: queueIndex,
                shuffleMode: shuffleMode,
                repeatMode: repeatMode,
              ),
            ),
          ),
          queueProvider.overrideWith((ref) => Stream.value(queue)),
          positionDataProvider.overrideWith(
            (ref) => Stream.value(PlayerPositionData.zero),
          ),
          volumeProvider.overrideWith((ref) => Stream.value(1.0)),
        ],
        child: const MaterialApp(home: PlayerScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  IconButton buttonWithIcon(WidgetTester tester, IconData icon) =>
      tester.widget<IconButton>(find.widgetWithIcon(IconButton, icon));

  testWidgets('shuffle inactif : gris, tap → active la lecture aléatoire', (
    tester,
  ) async {
    final handler = _FakeAudioHandler();
    await pumpPlayer(tester, handler: handler);

    expect(buttonWithIcon(tester, Icons.shuffle_rounded).color, Colors.white54);

    await tester.tap(find.byIcon(Icons.shuffle_rounded));
    await tester.pump();

    expect(handler.lastShuffleMode, AudioServiceShuffleMode.all);
    expect(handler.lastRepeatMode, isNull);
  });

  testWidgets('shuffle actif : vert, tap → désactive', (tester) async {
    final handler = _FakeAudioHandler();
    await pumpPlayer(
      tester,
      handler: handler,
      shuffleMode: AudioServiceShuffleMode.all,
    );

    expect(buttonWithIcon(tester, Icons.shuffle_rounded).color, _accent);

    await tester.tap(find.byIcon(Icons.shuffle_rounded));
    await tester.pump();

    expect(handler.lastShuffleMode, AudioServiceShuffleMode.none);
  });

  // NB : un test = un pumpWidget. Re-pomper avec d'autres overrides dans le
  // même test est sans effet (Riverpod ne relit pas les overrides d'un
  // ProviderScope déjà monté).
  testWidgets('repeat aucune : icône grise, tap → répéter la file', (
    tester,
  ) async {
    final handler = _FakeAudioHandler();
    await pumpPlayer(tester, handler: handler);

    expect(buttonWithIcon(tester, Icons.repeat_rounded).color, Colors.white54);
    await tester.tap(find.byIcon(Icons.repeat_rounded));
    await tester.pump();
    expect(handler.lastRepeatMode, AudioServiceRepeatMode.all);
  });

  testWidgets('repeat file : icône verte, tap → répéter la piste', (
    tester,
  ) async {
    final handler = _FakeAudioHandler();
    await pumpPlayer(
      tester,
      handler: handler,
      repeatMode: AudioServiceRepeatMode.all,
    );

    expect(buttonWithIcon(tester, Icons.repeat_rounded).color, _accent);
    await tester.tap(find.byIcon(Icons.repeat_rounded));
    await tester.pump();
    expect(handler.lastRepeatMode, AudioServiceRepeatMode.one);
  });

  testWidgets('repeat piste : icône repeat_one verte, tap → désactive', (
    tester,
  ) async {
    final handler = _FakeAudioHandler();
    await pumpPlayer(
      tester,
      handler: handler,
      repeatMode: AudioServiceRepeatMode.one,
    );

    expect(find.byIcon(Icons.repeat_one_rounded), findsOneWidget);
    expect(buttonWithIcon(tester, Icons.repeat_one_rounded).color, _accent);
    await tester.tap(find.byIcon(Icons.repeat_one_rounded));
    await tester.pump();
    expect(handler.lastRepeatMode, AudioServiceRepeatMode.none);
  });

  testWidgets('sans répétition : la file garde ses limites', (tester) async {
    final handler = _FakeAudioHandler();
    // Dernière piste d'une file de 3, ni shuffle ni répétition.
    await pumpPlayer(tester, handler: handler, queueLength: 3, queueIndex: 2);

    expect(buttonWithIcon(tester, Icons.skip_next_rounded).onPressed, isNull);
    expect(
      buttonWithIcon(tester, Icons.skip_previous_rounded).onPressed,
      isNotNull,
    );
  });

  testWidgets('répéter la file : suivant boucle en fin de file', (
    tester,
  ) async {
    final handler = _FakeAudioHandler();
    await pumpPlayer(
      tester,
      handler: handler,
      repeatMode: AudioServiceRepeatMode.all,
      queueLength: 3,
      queueIndex: 2,
    );

    expect(
      buttonWithIcon(tester, Icons.skip_next_rounded).onPressed,
      isNotNull,
    );
  });

  testWidgets('répéter la file : précédent boucle en début de file', (
    tester,
  ) async {
    final handler = _FakeAudioHandler();
    await pumpPlayer(
      tester,
      handler: handler,
      repeatMode: AudioServiceRepeatMode.all,
      queueLength: 3,
      queueIndex: 0,
    );

    expect(
      buttonWithIcon(tester, Icons.skip_previous_rounded).onPressed,
      isNotNull,
    );
  });

  testWidgets('shuffle actif : précédent/suivant restent disponibles', (
    tester,
  ) async {
    final handler = _FakeAudioHandler();
    await pumpPlayer(
      tester,
      handler: handler,
      shuffleMode: AudioServiceShuffleMode.all,
      queueLength: 3,
      queueIndex: 0,
    );

    expect(
      buttonWithIcon(tester, Icons.skip_previous_rounded).onPressed,
      isNotNull,
    );
    expect(
      buttonWithIcon(tester, Icons.skip_next_rounded).onPressed,
      isNotNull,
    );
  });
}

/// Faux handler : seuls setShuffleMode/setRepeatMode sont appelés par les
/// boutons testés ; tout autre appel échoue explicitement.
class _FakeAudioHandler implements HomeSpotifyAudioHandler {
  AudioServiceShuffleMode? lastShuffleMode;
  AudioServiceRepeatMode? lastRepeatMode;

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    lastShuffleMode = shuffleMode;
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    lastRepeatMode = repeatMode;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'appel inattendu au handler: ${invocation.memberName}',
  );
}
