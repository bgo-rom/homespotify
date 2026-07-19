import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

import 'package:homespotify_mobile/src/features/player/audio/homespotify_audio_handler.dart';
import 'package:homespotify_mobile/src/features/player/audio/time_stretch_engine.dart';
import 'package:homespotify_mobile/src/features/player/data/playback_settings_api.dart';

void main() {
  // Le moteur de vitesse interroge le canal de statut Android
  // (com.homespotify/stretch_engine) : le binding doit exister pour que
  // l'appel échoue proprement en MissingPluginException (→ mode compatible),
  // au lieu de lever « Binding has not yet been initialized ».
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'la cover locale remplace le placeholder sans recharger la source audio',
    () async {
      final player = _FakeQueueAudioPlayer();
      final cover = Completer<Uri?>();
      var resolverCalls = 0;
      final handler = HomeSpotifyAudioHandler(
        player: player,
        audioSessionSetup: Future<void>.value(),
        artworkResolver: (item) {
          resolverCalls += 1;
          return cover.future;
        },
      );
      addTearDown(handler.dispose);

      await handler.setQueueAndPlay(
        items: [
          PlayerQueueItem(
            id: '67',
            userId: 3,
            streamUri: Uri.parse('https://homespotify.test/67/stream'),
            artUri: Uri.parse('https://homespotify.test/67/cover'),
            title: 'Hurt me anymore',
            artist: 'purity.',
          ),
        ],
        initialIndex: 0,
      );
      await _eventLoop();

      expect(resolverCalls, 1);
      expect(handler.mediaItem.value?.artUri, isNull);
      expect(player.setAudioSourcesCalls, 1);
      expect(player.playCalls, 1);

      final localCover = Uri.file('cache/user_3_track_67_cover.jpg');
      cover.complete(localCover);
      await _eventLoop();

      expect(handler.mediaItem.value?.artUri, localCover);
      expect(handler.queue.value.single.artUri, localCover);
      expect(player.setAudioSourcesCalls, 1);
      expect(player.playCalls, 1);
      expect(player.currentIndex, 0);
    },
  );

  test(
    'une résolution lente A ne remplace jamais la cover de la piste B',
    () async {
      final player = _FakeQueueAudioPlayer();
      final coverA = Completer<Uri?>();
      final coverB = Completer<Uri?>();
      final resolverCalls = <String>[];
      final handler = HomeSpotifyAudioHandler(
        player: player,
        audioSessionSetup: Future<void>.value(),
        artworkResolver: (item) {
          resolverCalls.add(item.id);
          return item.id == '67' ? coverA.future : coverB.future;
        },
      );
      addTearDown(handler.dispose);
      await handler.setQueueAndPlay(
        items: [
          PlayerQueueItem(
            id: '67',
            userId: 3,
            streamUri: Uri.parse('https://homespotify.test/67/stream'),
            artUri: Uri.parse('https://homespotify.test/67/cover'),
            title: 'A',
          ),
          PlayerQueueItem(
            id: '68',
            userId: 3,
            streamUri: Uri.parse('https://homespotify.test/68/stream'),
            artUri: Uri.parse('https://homespotify.test/68/cover'),
            title: 'B',
          ),
        ],
        initialIndex: 0,
      );
      await _eventLoop();
      await handler.skipToQueueItem(1);
      await _eventLoop();

      final localB = Uri.file('cache/user_3_track_68_cover.jpg');
      coverB.complete(localB);
      await _eventLoop();
      expect(handler.mediaItem.value?.id, '68');
      expect(handler.mediaItem.value?.artUri, localB);

      coverA.complete(Uri.file('cache/user_3_track_67_cover.jpg'));
      await _eventLoop();
      expect(handler.mediaItem.value?.id, '68');
      expect(handler.mediaItem.value?.artUri, localB);

      await handler.skipToQueueItem(0);
      await _eventLoop();
      expect(handler.mediaItem.value?.id, '67');
      expect(
        handler.mediaItem.value?.artUri,
        Uri.file('cache/user_3_track_67_cover.jpg'),
      );
      expect(resolverCalls, <String>['67', '68', '67']);
      expect(player.setAudioSourcesCalls, 1);
      expect(player.playCalls, 1);
    },
  );

  test(
    'la vitesse ne déborde jamais sur la piste suivante et le pitch reste à 1',
    () async {
      final player = _FakeQueueAudioPlayer();
      final repository = _MemoryPlaybackSettingsRepository(<int, double>{
        1: 1.3,
      });
      final handler = HomeSpotifyAudioHandler(
        player: player,
        playbackSettingsRepository: repository,
        audioSessionSetup: Future<void>.value(),
      );
      addTearDown(handler.dispose);

      await handler.setQueueAndPlay(
        items: [
          PlayerQueueItem(
            id: '1',
            streamUri: Uri.parse('https://homespotify.test/1'),
            title: 'Piste A',
          ),
          PlayerQueueItem(
            id: '2',
            streamUri: Uri.parse('https://homespotify.test/2'),
            title: 'Piste B',
          ),
        ],
        initialIndex: 0,
      );

      // La lecture n'attend jamais le backend : 1.00x est visible d'abord,
      // puis le réglage arrive au tour d'événement suivant.
      expect(handler.currentTrackSpeed, 1.0);
      await _settleUntil(
        () =>
            handler.currentTrackSpeed == 1.3 &&
            handler.playbackState.value.speed == 1.3,
      );
      expect(handler.currentTrackSpeed, 1.3);
      expect(handler.currentPitch, 1.0);
      expect(handler.playbackState.value.speed, 1.3);

      await handler.skipToQueueItem(1);
      await _settleUntil(() => repository.fetchedTrackIds.contains(2));

      expect(repository.fetchedTrackIds, containsAllInOrder(<int>[1, 2]));
      expect(handler.currentTrackSpeed, 1.0);
      expect(handler.currentPitch, 1.0);
      expect(handler.playbackState.value.speed, 1.0);
      expect(player.appliedPitches, everyElement(1.0));
      expect(player.appliedSpeeds, containsAllInOrder(<double>[1.3, 1.0]));
    },
  );

  test(
    'setTrackSpeed arrondit, persiste et refuse une valeur hors limites',
    () async {
      final player = _FakeQueueAudioPlayer();
      final repository = _MemoryPlaybackSettingsRepository();
      final handler = HomeSpotifyAudioHandler(
        player: player,
        playbackSettingsRepository: repository,
        audioSessionSetup: Future<void>.value(),
      );
      addTearDown(handler.dispose);
      await handler.setQueueAndPlay(
        items: [
          PlayerQueueItem(
            id: '7',
            streamUri: Uri.parse('https://homespotify.test/7'),
            title: 'Piste',
          ),
        ],
        initialIndex: 0,
      );

      await handler.setTrackSpeed(7, 1.199999);
      expect(repository.values[7], 1.2);
      expect(handler.currentTrackSpeed, 1.2);
      expect(handler.currentPitch, 1.0);
      await expectLater(
        () => handler.setTrackSpeed(7, 1.31),
        throwsArgumentError,
      );
    },
  );

  test(
    'un refus du moteur restaure le ratio précédent sans persister',
    () async {
      final player = _FakeQueueAudioPlayer();
      final repository = _MemoryPlaybackSettingsRepository();
      final handler = HomeSpotifyAudioHandler(
        player: player,
        playbackSettingsRepository: repository,
        audioSessionSetup: Future<void>.value(),
      );
      addTearDown(handler.dispose);
      await handler.setQueueAndPlay(
        items: [
          PlayerQueueItem(
            id: '11',
            streamUri: Uri.parse('https://homespotify.test/11'),
            title: 'Piste',
          ),
        ],
        initialIndex: 0,
      );
      await _eventLoop();
      player.ignoreNextSpeedWrite = true;

      await expectLater(
        handler.setTrackSpeed(11, 0.8),
        throwsA(isA<TrackSpeedApplyException>()),
      );

      expect(handler.currentTrackSpeed, 1);
      expect(repository.saveCalls, isEmpty);
    },
  );

  test(
    'un échec backend conserve le ratio actif et un nouvel essai le persiste',
    () async {
      final player = _FakeQueueAudioPlayer();
      final repository = _MemoryPlaybackSettingsRepository()
        ..saveError = StateError('backend indisponible');
      final handler = HomeSpotifyAudioHandler(
        player: player,
        playbackSettingsRepository: repository,
        audioSessionSetup: Future<void>.value(),
      );
      addTearDown(handler.dispose);
      await handler.setQueueAndPlay(
        items: [
          PlayerQueueItem(
            id: '12',
            streamUri: Uri.parse('https://homespotify.test/12'),
            title: 'Piste',
          ),
        ],
        initialIndex: 0,
      );
      await _eventLoop();

      await expectLater(
        handler.setTrackSpeed(12, 0.8),
        throwsA(isA<TrackSpeedPersistenceException>()),
      );
      expect(handler.currentTrackSpeed, 0.8);
      expect(repository.values[12], isNull);

      repository.saveError = null;
      await handler.setTrackSpeed(12, 0.8);
      expect(repository.values[12], 0.8);
      expect(handler.currentTrackSpeed, 0.8);
    },
  );

  test(
    'un réglage de piste inactive ne touche pas au lecteur courant',
    () async {
      final player = _FakeQueueAudioPlayer();
      final repository = _MemoryPlaybackSettingsRepository();
      final handler = HomeSpotifyAudioHandler(
        player: player,
        playbackSettingsRepository: repository,
        audioSessionSetup: Future<void>.value(),
      );
      addTearDown(handler.dispose);
      await handler.setQueueAndPlay(
        items: [
          PlayerQueueItem(
            id: '21',
            streamUri: Uri.parse('https://homespotify.test/21'),
            title: 'Active',
          ),
          PlayerQueueItem(
            id: '22',
            streamUri: Uri.parse('https://homespotify.test/22'),
            title: 'Inactive',
          ),
        ],
        initialIndex: 0,
      );
      await _eventLoop();
      final writesBefore = player.appliedSpeeds.length;

      await handler.setTrackSpeed(22, 1.2);

      expect(repository.values[22], 1.2);
      expect(player.appliedSpeeds.length, writesBefore);
      expect(handler.currentTrackSpeed, 1);
    },
  );

  test('le constructeur ne touche ni au natif ni au réseau', () async {
    final player = _FakeQueueAudioPlayer();
    final repository = _MemoryPlaybackSettingsRepository();
    final handler = HomeSpotifyAudioHandler(
      player: player,
      playbackSettingsRepository: repository,
      audioSessionSetup: Future<void>.value(),
    );
    addTearDown(handler.dispose);

    await _eventLoop();

    expect(player.volumeWrites, 0);
    expect(player.appliedSpeeds, isEmpty);
    expect(player.appliedPitches, isEmpty);
    expect(repository.fetchedTrackIds, isEmpty);
  });

  test('une requête de vitesse pendante ne retarde pas la lecture', () async {
    final player = _FakeQueueAudioPlayer();
    final repository = _PendingPlaybackSettingsRepository();
    final handler = HomeSpotifyAudioHandler(
      player: player,
      playbackSettingsRepository: repository,
      audioSessionSetup: Future<void>.value(),
    );
    addTearDown(handler.dispose);

    await handler
        .setQueueAndPlay(
          items: [
            PlayerQueueItem(
              id: '9',
              streamUri: Uri.parse('https://homespotify.test/9'),
              title: 'Piste paresseuse',
            ),
          ],
          initialIndex: 0,
        )
        .timeout(const Duration(milliseconds: 100));
    await _settleUntil(() => repository.fetchCount == 1);

    expect(player.playing, isTrue);
    expect(handler.currentTrackSpeed, 1.0);
    // Le reset 1,00x est écrit de façon synchrone à la transition (L-040) ;
    // aucune vitesse NON neutre ne doit être appliquée tant que la requête
    // de réglage est pendante.
    expect(player.appliedSpeeds, everyElement(1.0));
    expect(repository.fetchCount, 1);
    repository.resolveDefault(9);
    await _eventLoop();
  });

  test(
    'le contrôle Android confirme le moteur PCM natif sans doubler la vitesse',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      const channel = MethodChannel('com.homespotify/stretch_engine');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'getStatus');
            return <String, Object?>{
              'engineMode': 'HOMESPOTIFY_STRETCH',
              'available': true,
              'active': true,
              'requestedRatio': 0.8,
              'appliedRatio': 0.8,
              'profile': 'MUSICAL',
              'latencyMs': 120,
              'pcmFramesProcessed': 4096,
              'averageDspMicros': 800,
              'maxDspMicros': 1200,
              'fallbackCount': 0,
              'underrunCount': 0,
              'lastError': null,
            };
          });
      addTearDown(() async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = null;
      });

      final player = _FakeQueueAudioPlayer();
      final engine = HomeSpotifyProductionTimeStretchEngine(
        player,
        channel: channel,
      );

      await engine.setTempoRatio(0.8);

      expect(player.appliedSpeeds, <double>[0.8]);
      expect(await engine.getAppliedTempoRatio(), 0.8);
      expect(engine.engineName, 'HomeSpotify Stretch Engine');
      expect(engine.qualityMode, TimeStretchQualityMode.standard);
      expect(currentTimeStretchQualityLabel, 'Qualité élevée');
    },
  );

  test(
    'la stratégie adaptative réserve les ratios éloignés au moteur HQ',
    () async {
      final compatible = _RecordingTimeStretchEngine('compatible');
      final highQuality = _RecordingTimeStretchEngine('hq');
      final engine = AdaptiveTimeStretchEngine(
        lowLatencyEngine: compatible,
        highQualityEngine: highQuality,
      );

      await engine.setTempoRatio(1.03);
      await engine.setTempoRatio(0.8);

      expect(compatible.ratios, <double>[1.03, 1]);
      expect(highQuality.ratios, <double>[0.8]);
      expect(engine.engineName, 'hq');
      expect(engine.qualityMode, TimeStretchQualityMode.enhanced);
    },
  );

  test('la stratégie retombe proprement sur le moteur compatible', () async {
    final compatible = _RecordingTimeStretchEngine('compatible');
    final highQuality = _RecordingTimeStretchEngine('hq')..failNext = true;
    final engine = AdaptiveTimeStretchEngine(
      lowLatencyEngine: compatible,
      highQualityEngine: highQuality,
    );

    await engine.setTempoRatio(0.7);

    expect(compatible.ratios, <double>[1, 0.7]);
    expect(highQuality.ratios, <double>[0.7, 1]);
    expect(engine.engineName, 'compatible');
    expect(engine.qualityMode, TimeStretchQualityMode.compatibilityFallback);
  });
}

Future<void> _eventLoop() async {
  for (var index = 0; index < 4; index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Attend une condition sur un nombre borné de tours d'événements : le canal
/// de statut du moteur ajoute des allers-retours asynchrones dont le nombre
/// exact n'est pas un contrat.
Future<void> _settleUntil(bool Function() condition) async {
  for (var index = 0; index < 400 && !condition(); index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _MemoryPlaybackSettingsRepository implements PlaybackSettingsRepository {
  _MemoryPlaybackSettingsRepository([Map<int, double>? initial])
    : values = <int, double>{...?initial};

  final Map<int, double> values;
  final List<int> fetchedTrackIds = <int>[];
  final List<int> saveCalls = <int>[];
  Object? saveError;

  @override
  Future<TrackPlaybackSettings> fetch(int trackId) async {
    fetchedTrackIds.add(trackId);
    final ratio = values[trackId] ?? 1;
    return TrackPlaybackSettings(
      trackId: trackId,
      speedRatio: ratio,
      preservePitch: true,
      isDefault: !values.containsKey(trackId),
    );
  }

  @override
  Future<TrackPlaybackSettings> save(int trackId, double speedRatio) async {
    saveCalls.add(trackId);
    final error = saveError;
    if (error != null) throw error;
    values[trackId] = speedRatio;
    return TrackPlaybackSettings(
      trackId: trackId,
      speedRatio: speedRatio,
      preservePitch: true,
      isDefault: false,
    );
  }

  @override
  Future<void> reset(int trackId) async => values.remove(trackId);

  @override
  Future<TrackAudioAnalysis> fetchAnalysis(int trackId) async =>
      TrackAudioAnalysis(trackId: trackId, status: 'PENDING');
}

class _PendingPlaybackSettingsRepository implements PlaybackSettingsRepository {
  final Completer<TrackPlaybackSettings> _fetchCompleter =
      Completer<TrackPlaybackSettings>();
  int fetchCount = 0;

  @override
  Future<TrackPlaybackSettings> fetch(int trackId) {
    fetchCount += 1;
    return _fetchCompleter.future;
  }

  void resolveDefault(int trackId) {
    if (_fetchCompleter.isCompleted) return;
    _fetchCompleter.complete(
      TrackPlaybackSettings(
        trackId: trackId,
        speedRatio: 1,
        preservePitch: true,
        isDefault: true,
      ),
    );
  }

  @override
  Future<TrackPlaybackSettings> save(int trackId, double speedRatio) =>
      throw UnimplementedError();

  @override
  Future<void> reset(int trackId) => throw UnimplementedError();

  @override
  Future<TrackAudioAnalysis> fetchAnalysis(int trackId) =>
      throw UnimplementedError();
}

class _FakeQueueAudioPlayer implements AudioPlayer {
  final StreamController<PlaybackEvent> _events =
      StreamController<PlaybackEvent>.broadcast();
  final StreamController<PlayerState> _states =
      StreamController<PlayerState>.broadcast();
  final StreamController<int?> _indexes = StreamController<int?>.broadcast();
  final StreamController<Duration> _positions =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> _buffered =
      StreamController<Duration>.broadcast();
  final StreamController<Duration?> _durations =
      StreamController<Duration?>.broadcast();
  final StreamController<double> _volumes =
      StreamController<double>.broadcast();

  final List<double> appliedSpeeds = <double>[];
  final List<double> appliedPitches = <double>[];
  int setAudioSourcesCalls = 0;
  int playCalls = 0;
  int volumeWrites = 0;
  bool ignoreNextSpeedWrite = false;
  double _speed = 1;
  double _pitch = 1;
  double _volume = 1;
  bool _playing = false;
  int? _currentIndex;
  final Duration _duration = const Duration(minutes: 3);
  ProcessingState _processingState = ProcessingState.idle;

  PlaybackEvent get _event => PlaybackEvent(
    processingState: _processingState,
    currentIndex: _currentIndex,
    duration: _duration,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #playbackEventStream:
        return _events.stream;
      case #playerStateStream:
        return _states.stream;
      case #currentIndexStream:
        return _indexes.stream;
      case #positionStream:
        return _positions.stream;
      case #bufferedPositionStream:
        return _buffered.stream;
      case #durationStream:
        return _durations.stream;
      case #volumeStream:
        return _volumes.stream;
      case #playbackEvent:
        return _event;
      case #position:
      case #bufferedPosition:
        return Duration.zero;
      case #duration:
        return _duration;
      case #processingState:
        return _processingState;
      case #currentIndex:
        return _currentIndex;
      case #playing:
        return _playing;
      case #speed:
        return _speed;
      case #pitch:
        return _pitch;
      case #volume:
        return _volume;
      case #shuffleModeEnabled:
        return false;
      case #shuffleIndices:
        return <int>[0, 1];
      case #sequence:
        return const <IndexedAudioSource>[];
      case #setVolume:
        _volume = invocation.positionalArguments.first as double;
        volumeWrites += 1;
        _volumes.add(_volume);
        return Future<void>.value();
      case #setSpeed:
        final requested = invocation.positionalArguments.first as double;
        appliedSpeeds.add(requested);
        if (ignoreNextSpeedWrite) {
          ignoreNextSpeedWrite = false;
          return Future<void>.value();
        }
        _speed = requested;
        return Future<void>.value();
      case #setPitch:
        _pitch = invocation.positionalArguments.first as double;
        appliedPitches.add(_pitch);
        return Future<void>.value();
      case #setAudioSources:
        setAudioSourcesCalls += 1;
        _currentIndex = invocation.namedArguments[#initialIndex] as int? ?? 0;
        _processingState = ProcessingState.ready;
        _indexes.add(_currentIndex);
        _events.add(_event);
        _states.add(PlayerState(_playing, _processingState));
        return Future<Duration?>.value(_duration);
      case #pause:
        _playing = false;
        _states.add(PlayerState(false, _processingState));
        return Future<void>.value();
      case #play:
        playCalls += 1;
        _playing = true;
        _states.add(PlayerState(true, _processingState));
        return Future<void>.value();
      case #seek:
        final index = invocation.namedArguments[#index] as int?;
        if (index != null) {
          _currentIndex = index;
          _indexes.add(index);
          _events.add(_event);
        }
        return Future<void>.value();
      case #setLoopMode:
      case #stop:
        return Future<void>.value();
      case #dispose:
        return Future.wait<void>([
          _events.close(),
          _states.close(),
          _indexes.close(),
          _positions.close(),
          _buffered.close(),
          _durations.close(),
          _volumes.close(),
        ]);
      default:
        throw UnimplementedError(
          'FakeQueueAudioPlayer: ${invocation.memberName}',
        );
    }
  }
}

class _RecordingTimeStretchEngine implements TimeStretchEngine {
  _RecordingTimeStretchEngine(this.engineName);

  final List<double> ratios = <double>[];
  double _ratio = 1;
  bool failNext = false;

  @override
  final String engineName;

  @override
  bool get isAvailable => true;

  @override
  int get latencyMs => 40;

  @override
  String? get lastError => null;

  @override
  TimeStretchQualityMode get qualityMode => TimeStretchQualityMode.enhanced;

  @override
  Future<void> dispose() async {}

  @override
  Future<double> getAppliedTempoRatio() async => _ratio;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> reset() => setTempoRatio(1);

  @override
  Future<void> setTempoRatio(double ratio) async {
    ratios.add(ratio);
    if (failNext) {
      failNext = false;
      throw StateError('moteur surchargé');
    }
    _ratio = ratio;
  }
}
