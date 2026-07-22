import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:homespotify_mobile/src/features/player/audio/homespotify_audio_handler.dart';
import 'package:homespotify_mobile/src/features/player/presentation/player_providers.dart';
import 'package:homespotify_mobile/src/features/player/presentation/widgets/mini_player.dart';

void main() {
  const queue3 = <MediaItem>[
    MediaItem(id: '1', title: 'Genesis', artist: 'Justice'),
    MediaItem(id: '2', title: 'Stress', artist: 'Justice'),
    MediaItem(id: '3', title: 'Waters of Nazareth', artist: 'Justice'),
  ];

  Future<void> pumpMini(WidgetTester tester, {required int queueIndex}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mediaItemProvider.overrideWith(
            (ref) => Stream.value(queue3[queueIndex]),
          ),
          playbackStateProvider.overrideWith(
            (ref) => Stream.value(
              PlaybackState(
                playing: true,
                processingState: AudioProcessingState.ready,
                queueIndex: queueIndex,
              ),
            ),
          ),
          queueProvider.overrideWith((ref) => Stream.value(queue3)),
          positionDataProvider.overrideWith(
            (ref) => Stream.value(
              const PlayerPositionData(
                position: Duration(seconds: 30),
                bufferedPosition: Duration(seconds: 45),
                duration: Duration(seconds: 60),
              ),
            ),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(bottomNavigationBar: MiniPlayer()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  VoidCallback? onPressedOf(WidgetTester tester, IconData icon) => tester
      .widget<IconButton>(find.widgetWithIcon(IconButton, icon))
      .onPressed;

  testWidgets('début de file : précédent désactivé, suivant actif', (
    tester,
  ) async {
    await pumpMini(tester, queueIndex: 0);

    expect(onPressedOf(tester, Icons.skip_previous_rounded), isNull);
    expect(onPressedOf(tester, Icons.skip_next_rounded), isNotNull);
  });

  testWidgets('fin de file : précédent actif, suivant désactivé', (
    tester,
  ) async {
    await pumpMini(tester, queueIndex: 2);

    expect(onPressedOf(tester, Icons.skip_previous_rounded), isNotNull);
    expect(onPressedOf(tester, Icons.skip_next_rounded), isNull);
  });

  testWidgets(
    'milieu de file : contrôles et progression restent synchronisés',
    (tester) async {
      await pumpMini(tester, queueIndex: 1);

      expect(onPressedOf(tester, Icons.skip_previous_rounded), isNotNull);
      expect(onPressedOf(tester, Icons.skip_next_rounded), isNotNull);
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
      final progress = tester.widget<LinearProgressIndicator>(
        find.byKey(const ValueKey('mini-player-progress')),
      );
      expect(progress.value, 0.5);
    },
  );
}
