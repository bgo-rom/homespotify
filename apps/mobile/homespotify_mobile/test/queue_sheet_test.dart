import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:homespotify_mobile/src/features/player/audio/homespotify_audio_handler.dart';
import 'package:homespotify_mobile/src/features/player/presentation/player_providers.dart';
import 'package:homespotify_mobile/src/features/player/presentation/queue_screen.dart';

void main() {
  const queue = <MediaItem>[
    MediaItem(
      id: '1',
      title: 'Genesis',
      artist: 'Justice',
      duration: Duration(minutes: 3, seconds: 20),
      extras: {'origin': 'Album'},
    ),
    MediaItem(
      id: '2',
      title: 'Stress',
      artist: 'Justice',
      duration: Duration(minutes: 4),
      extras: {'origin': 'Playlist'},
    ),
    MediaItem(
      id: '3',
      title: 'Waters of Nazareth',
      artist: 'Justice',
      duration: Duration(minutes: 3),
      extras: {'origin': 'Bibliothèque'},
    ),
  ];

  Future<void> pumpQueue(
    WidgetTester tester, {
    required _FakeAudioHandler handler,
    List<MediaItem> items = queue,
    int queueIndex = 0,
  }) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          audioHandlerProvider.overrideWithValue(handler),
          queueProvider.overrideWith((ref) => Stream.value(items)),
          mediaItemProvider.overrideWith(
            (ref) => Stream.value(
              queueIndex >= 0 && queueIndex < items.length
                  ? items[queueIndex]
                  : null,
            ),
          ),
          playbackStateProvider.overrideWith(
            (ref) => Stream.value(
              PlaybackState(
                playing: items.isNotEmpty,
                processingState: AudioProcessingState.ready,
                queueIndex: queueIndex,
              ),
            ),
          ),
          positionDataProvider.overrideWith(
            (ref) => Stream.value(
              const PlayerPositionData(
                position: Duration(seconds: 30),
                bufferedPosition: Duration(seconds: 40),
                duration: Duration(minutes: 3, seconds: 20),
              ),
            ),
          ),
        ],
        child: const MaterialApp(home: QueueScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('file unifiée : piste courante, lecture immédiate et retrait', (
    tester,
  ) async {
    final handler = _FakeAudioHandler();
    await pumpQueue(tester, handler: handler);

    expect(find.text('File d’attente'), findsOneWidget);
    expect(find.byKey(const ValueKey('queue-current-track')), findsOneWidget);
    expect(find.text('Genesis'), findsOneWidget);
    expect(find.text('Stress'), findsOneWidget);
    expect(find.textContaining('Playlist'), findsOneWidget);

    await tester.tap(find.byTooltip('Actions de la piste').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lire maintenant'));
    await tester.pump();
    expect(handler.lastSkippedIndex, 1);

    await tester.drag(
      find.byKey(const ValueKey('dismiss-3-2')),
      const Offset(-500, 0),
    );
    await tester.pumpAndSettle();
    expect(handler.lastRemovedIndex, 2);
  });

  testWidgets('réordonne puis vide seulement les pistes à suivre', (
    tester,
  ) async {
    final handler = _FakeAudioHandler();
    await pumpQueue(tester, handler: handler);

    final list = tester.widget<ReorderableListView>(
      find.byType(ReorderableListView),
    );
    list.onReorderItem!(0, 1);
    await tester.pump();
    expect(handler.lastReorder, (1, 2));

    await tester.tap(find.byKey(const ValueKey('queue-clear-upcoming')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Vider'),
      ),
    );
    await tester.pumpAndSettle();
    expect(handler.clearUpcomingCalls, 1);
    expect(handler.stopCalls, 0);
  });

  testWidgets('état vide premium renvoie vers la bibliothèque', (tester) async {
    await pumpQueue(
      tester,
      handler: _FakeAudioHandler(),
      items: const [],
      queueIndex: -1,
    );

    expect(find.text('La file est vide'), findsOneWidget);
    expect(find.byKey(const ValueKey('queue-browse-library')), findsOneWidget);
  });
}

class _FakeAudioHandler implements HomeSpotifyAudioHandler {
  int? lastSkippedIndex;
  int? lastRemovedIndex;
  (int, int)? lastReorder;
  int clearUpcomingCalls = 0;
  int stopCalls = 0;

  @override
  Future<void> skipToQueueItem(int index) async => lastSkippedIndex = index;

  @override
  Future<void> removeQueueItemAt(int index) async => lastRemovedIndex = index;

  @override
  Future<void> reorderQueueItem(int oldIndex, int newIndex) async {
    lastReorder = (oldIndex, newIndex);
  }

  @override
  Future<void> clearUpcoming() async => clearUpcomingCalls += 1;

  @override
  Future<void> stop() async => stopCalls += 1;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'appel inattendu au handler: ${invocation.memberName}',
  );
}
