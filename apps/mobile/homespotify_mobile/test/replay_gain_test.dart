import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homespotify_mobile/src/features/player/audio/replay_gain.dart';
import 'package:just_audio/just_audio.dart';

void main() {
  test('désactivé par défaut : aucune mesure ni gain appliqué', () async {
    final media = StreamController<MediaItem?>.broadcast();
    final repository = _FakeRepository(enabled: false);
    final engine = _FakeEngine();
    final controller = ReplayGainController(
      repository: repository,
      engine: engine,
      mediaItems: media.stream,
    );

    await controller.initialize();
    media.add(const MediaItem(id: '7', title: 'Titre'));
    await _settle();

    expect(controller.state.value.phase, ReplayGainPhase.disabled);
    expect(repository.resolvedTrackIds, isEmpty);
    expect(engine.calls.whereType<double>(), isEmpty);
    await controller.dispose();
    await media.close();
  });

  test('une mesure READY applique le gain borné au titre courant', () async {
    final media = StreamController<MediaItem?>.broadcast();
    final repository = _FakeRepository(
      enabled: true,
      responses: [
        const ReplayGainAnalysis(
          trackId: 7,
          status: 'READY',
          integratedLufs: -12,
          truePeakDbfs: -1.2,
          replayGainDb: -6,
        ),
      ],
    );
    final engine = _FakeEngine();
    final controller = ReplayGainController(
      repository: repository,
      engine: engine,
      mediaItems: media.stream,
    );

    await controller.initialize();
    media.add(const MediaItem(id: '7', title: 'Titre'));
    await _settleUntil(
      () => controller.state.value.phase == ReplayGainPhase.applied,
    );

    expect(controller.state.value.appliedGainDb, -6);
    expect(engine.calls.last, -6);
    expect(repository.resolvedTrackIds, [7]);
    await controller.dispose();
    await media.close();
  });

  test('PENDING est repollé puis READY, sans bloquer la lecture', () async {
    final media = StreamController<MediaItem?>.broadcast();
    final repository = _FakeRepository(
      enabled: true,
      responses: [
        const ReplayGainAnalysis(trackId: 9, status: 'PENDING'),
        const ReplayGainAnalysis(
          trackId: 9,
          status: 'READY',
          integratedLufs: -20,
          truePeakDbfs: -5,
          replayGainDb: 2,
        ),
      ],
    );
    final engine = _FakeEngine();
    final controller = ReplayGainController(
      repository: repository,
      engine: engine,
      mediaItems: media.stream,
      pollInterval: const Duration(milliseconds: 1),
      maxPollAttempts: 2,
    );

    await controller.initialize();
    media.add(const MediaItem(id: '9', title: 'Titre'));
    await _settleUntil(
      () => controller.state.value.phase == ReplayGainPhase.applied,
    );

    expect(repository.resolvedTrackIds, [9, 9]);
    expect(engine.calls.last, 2);
    await controller.dispose();
    await media.close();
  });

  test(
    'changer de titre annule une mesure tardive et réinitialise le gain',
    () async {
      final media = StreamController<MediaItem?>.broadcast();
      final first = Completer<ReplayGainAnalysis>();
      final repository = _CompleterRepository(first);
      final engine = _FakeEngine();
      final controller = ReplayGainController(
        repository: repository,
        engine: engine,
        mediaItems: media.stream,
        maxPollAttempts: 0,
      );

      await controller.initialize();
      media.add(const MediaItem(id: '1', title: 'Premier'));
      await _settle();
      media.add(const MediaItem(id: '2', title: 'Second'));
      await _settle();
      first.complete(
        const ReplayGainAnalysis(
          trackId: 1,
          status: 'READY',
          integratedLufs: -10,
          truePeakDbfs: -1,
          replayGainDb: -8,
        ),
      );
      await _settle();

      expect(engine.calls, isNot(contains(-8)));
      expect(controller.state.value.trackId, 2);
      await controller.dispose();
      await media.close();
    },
  );

  test(
    'le gain du nouveau titre attend la remise à zéro du précédent',
    () async {
      final media = StreamController<MediaItem?>.broadcast();
      final repository = _FakeRepository(
        enabled: true,
        responses: [
          const ReplayGainAnalysis(
            trackId: 12,
            status: 'READY',
            integratedLufs: -14,
            truePeakDbfs: -2,
            replayGainDb: -4,
          ),
        ],
      );
      final reset = Completer<void>();
      final engine = _BlockingSecondResetEngine(reset);
      final controller = ReplayGainController(
        repository: repository,
        engine: engine,
        mediaItems: media.stream,
      );

      await controller.initialize();
      media.add(const MediaItem(id: '12', title: 'Titre'));
      await _settle();

      expect(repository.resolvedTrackIds, isEmpty);
      reset.complete();
      await _settleUntil(
        () => controller.state.value.phase == ReplayGainPhase.applied,
      );
      expect(repository.resolvedTrackIds, [12]);
      expect(engine.calls.last, -4);

      await controller.dispose();
      await media.close();
    },
  );

  test(
    'désactiver remet immédiatement l’effet à zéro et persiste le choix',
    () async {
      final media = StreamController<MediaItem?>.broadcast();
      final repository = _FakeRepository(enabled: true);
      final engine = _FakeEngine();
      final controller = ReplayGainController(
        repository: repository,
        engine: engine,
        mediaItems: media.stream,
      );

      await controller.initialize();
      await controller.setEnabled(false);

      expect(repository.savedEnabled, false);
      expect(controller.state.value.phase, ReplayGainPhase.disabled);
      expect(engine.calls.last, isNull);
      await controller.dispose();
      await media.close();
    },
  );

  test('le moteur Android sépare atténuation et amplification', () async {
    final enhancer = AndroidLoudnessEnhancer();
    final attenuations = <double?>[];
    final engine = AndroidReplayGainEngine(
      enhancer,
      attenuationApplier: (gainDb) async => attenuations.add(gainDb),
    );

    await engine.applyGainDb(-6);
    expect(enhancer.enabled, isFalse);
    expect(enhancer.targetGain, 0);
    expect(attenuations.last, -6);

    await engine.applyGainDb(3);
    expect(attenuations.last, isNull);
    expect(enhancer.targetGain, 3);
    expect(enhancer.enabled, isTrue);

    await engine.applyGainDb(null);
    expect(enhancer.enabled, isFalse);
    expect(enhancer.targetGain, 0);
    expect(attenuations.last, isNull);
  });
}

class _FakeRepository implements ReplayGainRepository {
  _FakeRepository({
    required this.enabled,
    List<ReplayGainAnalysis> responses = const [],
  }) : _responses = List.of(responses);

  final bool enabled;
  final List<ReplayGainAnalysis> _responses;
  final List<int> resolvedTrackIds = [];
  bool? savedEnabled;

  @override
  Future<bool> loadEnabled() async => enabled;

  @override
  Future<ReplayGainAnalysis> resolve(int trackId) async {
    resolvedTrackIds.add(trackId);
    if (_responses.isEmpty) {
      return ReplayGainAnalysis(trackId: trackId, status: 'FAILED');
    }
    return _responses.removeAt(0);
  }

  @override
  Future<void> saveEnabled(bool enabled) async {
    savedEnabled = enabled;
  }
}

class _CompleterRepository implements ReplayGainRepository {
  _CompleterRepository(this.first);

  final Completer<ReplayGainAnalysis> first;
  var calls = 0;

  @override
  Future<bool> loadEnabled() async => true;

  @override
  Future<ReplayGainAnalysis> resolve(int trackId) {
    calls += 1;
    if (calls == 1) return first.future;
    return Future.value(ReplayGainAnalysis(trackId: trackId, status: 'FAILED'));
  }

  @override
  Future<void> saveEnabled(bool enabled) async {}
}

class _FakeEngine implements ReplayGainEngine {
  final List<double?> calls = [];

  @override
  Future<void> applyGainDb(double? gainDb) async {
    calls.add(gainDb);
  }
}

class _BlockingSecondResetEngine implements ReplayGainEngine {
  _BlockingSecondResetEngine(this.reset);

  final Completer<void> reset;
  final List<double?> calls = [];
  var nullCalls = 0;

  @override
  Future<void> applyGainDb(double? gainDb) async {
    calls.add(gainDb);
    if (gainDb == null && ++nullCalls == 2) {
      await reset.future;
    }
  }
}

Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

Future<void> _settleUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 50 && !condition(); attempt += 1) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(condition(), isTrue);
}
