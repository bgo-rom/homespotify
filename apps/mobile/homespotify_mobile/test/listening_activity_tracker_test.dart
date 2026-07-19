import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:homespotify_mobile/src/features/listening/application/listening_activity_tracker.dart';
import 'package:homespotify_mobile/src/features/listening/data/listening_activity_api.dart';
import 'package:homespotify_mobile/src/features/listening/data/listening_event_store.dart';
import 'package:homespotify_mobile/src/features/player/audio/homespotify_audio_handler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'homespotify_installation_id': '33333333-3333-4333-8333-333333333333',
    });
  });

  testWidgets('démarre réellement, progresse à 30 s et pause le cumul', (
    tester,
  ) async {
    final playback = _FakePlaybackSource();
    final store = _FakeStore();
    final api = _FakeApi();
    var monotonicMs = 0;
    final tracker = ListeningActivityTracker(
      userId: 7,
      playback: playback,
      api: api,
      store: store,
      monotonicMilliseconds: () => monotonicMs,
      clock: () => DateTime.utc(2026, 7, 16, 12),
    )..start();
    await tester.pump();

    playback.media.add(
      const MediaItem(
        id: '67',
        title: 'Titre',
        duration: Duration(seconds: 120),
      ),
    );
    await tester.pump();
    expect(store.allPayloads, isEmpty);

    playback.states.add(
      PlaybackState(playing: true, processingState: AudioProcessingState.ready),
    );
    await tester.pump();
    expect(store.allPayloads.single['type'], 'PLAY_STARTED');

    for (var second = 1; second <= 31; second++) {
      monotonicMs = second * 1000;
      await tester.pump(const Duration(seconds: 1));
    }
    expect(
      store.allPayloads.map((event) => event['type']),
      contains('PLAY_PROGRESS'),
    );
    final progress = store.allPayloads.last;
    expect(progress['listenedMs'], greaterThanOrEqualTo(30_000));

    playback.states.add(
      PlaybackState(
        playing: false,
        processingState: AudioProcessingState.ready,
      ),
    );
    await tester.pump();
    expect(store.allPayloads.last['type'], 'PLAY_PAUSED');
    final pausedMs = store.allPayloads.last['listenedMs'];
    monotonicMs = 90_000;
    await tester.pump(const Duration(seconds: 2));
    expect(store.allPayloads.last['listenedMs'], pausedMs);
    tracker.dispose();
    await tester.pump();
  });

  testWidgets('reprise et reconstruction de source conservent la session', (
    tester,
  ) async {
    final playback = _FakePlaybackSource();
    final store = _FakeStore();
    final tracker = ListeningActivityTracker(
      userId: 8,
      playback: playback,
      api: _FakeApi(),
      store: store,
      monotonicMilliseconds: () => 0,
    )..start();
    await tester.pump();
    playback.media.add(const MediaItem(id: '68', title: 'Titre'));
    playback.states.add(
      PlaybackState(playing: true, processingState: AudioProcessingState.ready),
    );
    await tester.pump();
    final session = store.allPayloads.single['clientSessionId'];
    playback.states.add(
      PlaybackState(
        playing: false,
        processingState: AudioProcessingState.loading,
      ),
    );
    playback.states.add(
      PlaybackState(playing: true, processingState: AudioProcessingState.ready),
    );
    await tester.pump();
    expect(store.allPayloads.map((event) => event['clientSessionId']).toSet(), {
      session,
    });
    expect(
      store.allPayloads.where((event) => event['type'] == 'PLAY_STARTED'),
      hasLength(1),
    );
    tracker.dispose();
    await tester.pump();
  });

  testWidgets(
    'backend indisponible : événement conservé et aucun timer restant',
    (tester) async {
      final playback = _FakePlaybackSource();
      final store = _FakeStore();
      final api = _FakeApi()..fail = true;
      final tracker = ListeningActivityTracker(
        userId: 9,
        playback: playback,
        api: api,
        store: store,
      )..start();
      await tester.pump();
      playback.media.add(const MediaItem(id: '69', title: 'Titre'));
      playback.states.add(
        PlaybackState(
          playing: true,
          processingState: AudioProcessingState.ready,
        ),
      );
      await tester.pump();
      expect(store.pendingRows, isNotEmpty);
      tracker.dispose();
      await tester.pump(const Duration(seconds: 10));
    },
  );
}

class _FakePlaybackSource implements ListeningPlaybackSource {
  final media = StreamController<MediaItem?>.broadcast(sync: true);
  final states = StreamController<PlaybackState>.broadcast(sync: true);
  final position = StreamController<PlayerPositionData>.broadcast(sync: true);

  @override
  Stream<MediaItem?> get mediaItems => media.stream;
  @override
  Stream<PlaybackState> get playbackStates => states.stream;
  @override
  Stream<PlayerPositionData> get positions => position.stream;
}

class _FakeApi extends ListeningActivityApi {
  _FakeApi() : super(Dio());
  bool fail = false;
  final sent = <List<Map<String, dynamic>>>[];

  @override
  Future<void> sendBatch(List<Map<String, dynamic>> events) async {
    if (fail) throw const ListeningActivityApiException('hors ligne');
    sent.add(events);
  }
}

class _FakeStore implements ListeningEventStore {
  int _id = 0;
  final pendingRows = <PendingListeningEvent>[];
  final allPayloads = <Map<String, dynamic>>[];

  @override
  Future<void> enqueue(int userId, Map<String, dynamic> payload) async {
    allPayloads.add(payload);
    pendingRows.add(PendingListeningEvent(id: ++_id, payload: payload));
  }

  @override
  Future<List<PendingListeningEvent>> pending(
    int userId, {
    int limit = 50,
  }) async => pendingRows.take(limit).toList(growable: false);

  @override
  Future<void> acknowledge(Iterable<int> ids) async {
    final values = ids.toSet();
    pendingRows.removeWhere((row) => values.contains(row.id));
  }

  @override
  Future<void> markRetry(
    Iterable<int> ids,
    String category,
    DateTime nextAttemptAt,
  ) async {}
}
