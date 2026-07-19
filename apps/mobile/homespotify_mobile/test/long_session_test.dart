import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

import 'package:homespotify_mobile/src/features/player/audio/audio_diagnostics.dart';
import 'package:homespotify_mobile/src/features/player/audio/homespotify_audio_handler.dart';

/// Fiabilité des longues sessions : une file de 20 pistes doit s'enchaîner
/// sans intervention ; une piste irrécupérable est sautée (borné) ; un token
/// expiré est rafraîchi À CHAQUE expiration, pas seulement la première.
///
/// Tout est déterministe : faux lecteur contrôlable, fausse horloge, aucun
/// réseau, aucun vrai token.
void main() {
  // Le moteur de vitesse interroge le canal com.homespotify/stretch_engine :
  // le binding doit exister pour un échec propre (MissingPluginException →
  // mode compatible), voir playback_speed_test.
  TestWidgetsFlutterBinding.ensureInitialized();

  // Message réaliste d'un 401 remonté par le fork (cause incluse depuis la
  // correction de onPlayerError — auparavant Dart ne recevait que
  // « Source error » et ne déclenchait jamais le refresh).
  PlayerException authError() => PlayerException(
    0,
    'Source error <- InvalidResponseCodeException: Response code: 401',
    null,
  );

  PlayerException sourceError([String cause = 'FileDataSourceException']) =>
      PlayerException(0, 'Source error <- $cause: unreadable', null);

  List<PlayerQueueItem> makeQueue(int count) => [
    for (var index = 0; index < count; index++)
      PlayerQueueItem(
        id: '${index + 1}',
        streamUri: Uri.parse('https://homespotify.test/${index + 1}/stream'),
        title: 'Piste ${index + 1}',
        headers: const {'Authorization': 'Bearer initial'},
      ),
  ];

  Future<void> settleUntil(bool Function() condition) async {
    for (var turn = 0; turn < 400 && !condition(); turn++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  ({
    _LongSessionFakePlayer player,
    HomeSpotifyAudioHandler handler,
    _FakeClock clock,
    List<String> refreshLog,
  })
  makeRig({int refreshResult = -1}) {
    final player = _LongSessionFakePlayer();
    final clock = _FakeClock();
    final refreshLog = <String>[];
    var tokenGeneration = 0;
    final handler = HomeSpotifyAudioHandler(
      player: player,
      audioSessionSetup: Future<void>.value(),
      clock: clock.now,
      authorizationRefresh: () async {
        refreshLog.add('refresh');
        if (refreshResult >= 0 && refreshLog.length > refreshResult) {
          return false;
        }
        tokenGeneration += 1;
        return true;
      },
      currentAuthorizationHeaders: () => {
        'Authorization': 'Bearer renewed-$tokenGeneration',
      },
    );
    addTearDown(handler.dispose);
    return (
      player: player,
      handler: handler,
      clock: clock,
      refreshLog: refreshLog,
    );
  }

  test('20 pistes s’enchaînent sans arrêt ni erreur (index 0 → 19)', () async {
    final rig = makeRig();
    await rig.handler.setQueueAndPlay(items: makeQueue(20), initialIndex: 0);
    await settleUntil(() => rig.player.playCalls == 1);

    // La file logique et la séquence native sont complètes et identiques.
    expect(rig.handler.queue.value.length, 20);
    expect(rig.player.sequence.length, 20);
    expect(rig.player.currentIndex, 0);

    final publishedIndexes = <int>[0];
    for (var index = 1; index < 20; index++) {
      rig.player.advanceToIndex(index);
      await settleUntil(
        () => rig.handler.playbackState.value.queueIndex == index,
      );
      expect(rig.handler.playbackState.value.queueIndex, index);
      expect(rig.handler.mediaItem.value?.id, '${index + 1}');
      expect(
        rig.handler.playbackState.value.processingState,
        isNot(AudioProcessingState.error),
      );
      publishedIndexes.add(index);
    }
    expect(publishedIndexes, List<int>.generate(20, (i) => i));

    // Fin de file : état completed, jamais un état d'erreur silencieux.
    rig.player.completeQueue();
    await settleUntil(
      () =>
          rig.handler.playbackState.value.processingState ==
          AudioProcessingState.completed,
    );
    expect(rig.player.setAudioSourcesCalls, 1);
  });

  test('une durée inconnue ne bloque pas l’enchaînement', () async {
    final rig = makeRig();
    rig.player.loadedDuration = null;
    await rig.handler.setQueueAndPlay(items: makeQueue(3), initialIndex: 0);
    await settleUntil(() => rig.player.playCalls == 1);
    rig.player.advanceToIndex(1);
    await settleUntil(() => rig.handler.playbackState.value.queueIndex == 1);
    expect(rig.handler.mediaItem.value?.id, '2');
    expect(
      rig.handler.playbackState.value.processingState,
      isNot(AudioProcessingState.error),
    );
  });

  test('une piste 404 au milieu est sautée et la file continue', () async {
    final rig = makeRig();
    await rig.handler.setQueueAndPlay(items: makeQueue(20), initialIndex: 0);
    await settleUntil(() => rig.player.playCalls == 1);
    for (var index = 1; index <= 5; index++) {
      rig.player.advanceToIndex(index);
      await settleUntil(
        () => rig.handler.playbackState.value.queueIndex == index,
      );
    }

    // La piste 6 (index 5) est irrécupérable : 404.
    rig.player.emitError(
      sourceError('InvalidResponseCodeException: Response code: 404'),
    );
    await settleUntil(() => rig.player.setAudioSourcesCalls == 2);

    // Reprise automatique sur l'index suivant, sans état d'erreur global.
    expect(rig.player.lastInitialIndex, 6);
    await settleUntil(() => rig.player.playCalls >= 2);
    expect(
      rig.handler.playbackState.value.processingState,
      isNot(AudioProcessingState.error),
    );
    expect(rig.refreshLog, isEmpty); // un 404 ne déclenche aucun refresh
  });

  test('les sauts après erreur sont bornés : jamais de boucle infinie', () async {
    final rig = makeRig();
    await rig.handler.setQueueAndPlay(items: makeQueue(20), initialIndex: 0);
    await settleUntil(() => rig.player.playCalls == 1);

    // Quatre échecs consécutifs sans qu'aucune piste ne démarre réellement
    // (le compteur ne se réarme qu'à une lecture effective).
    rig.player.suppressReadyOnPlay = true;
    for (var attempt = 0; attempt < 4; attempt++) {
      final callsBefore = rig.player.setAudioSourcesCalls;
      rig.player.emitError(sourceError());
      await settleUntil(
        () =>
            rig.player.setAudioSourcesCalls > callsBefore ||
            rig.handler.playbackState.value.processingState ==
                AudioProcessingState.error,
      );
    }

    // 3 sauts maximum (1 chargement initial + 3 reprises), puis échec visible :
    // plus aucune reprise, lecture arrêtée, échec journalisé.
    expect(rig.player.setAudioSourcesCalls, 4);
    expect(rig.handler.playbackState.value.playing, isFalse);
    expect(
      AudioDiagnostics.instance.snapshot().join('\n'),
      contains('AUDIO_ERROR_SKIP_LIMIT_REACHED'),
    );
    expect(
      AudioDiagnostics.instance.snapshot().join('\n'),
      contains('AUDIO_PLAYBACK_FAILED'),
    );
  });

  test(
    'chaque expiration de token est récupérée, pas seulement la première',
    () async {
      final rig = makeRig();
      await rig.handler.setQueueAndPlay(items: makeQueue(20), initialIndex: 0);
      await settleUntil(() => rig.player.playCalls == 1);
      for (var index = 1; index <= 4; index++) {
        rig.player.advanceToIndex(index);
        await settleUntil(
          () => rig.handler.playbackState.value.queueIndex == index,
        );
      }

      // Première expiration (~15 min) : 401 → refresh → reprise sur place.
      rig.player.emitError(authError());
      await settleUntil(() => rig.player.setAudioSourcesCalls == 2);
      expect(rig.refreshLog.length, 1);
      expect(rig.player.lastInitialIndex, 4); // même piste, pas de saut
      expect(rig.player.lastHeaders?['Authorization'], 'Bearer renewed-1');
      await settleUntil(() => rig.player.playCalls >= 2);
      expect(
        rig.handler.playbackState.value.processingState,
        isNot(AudioProcessingState.error),
      );

      // La session continue…
      for (var index = 5; index <= 9; index++) {
        rig.player.advanceToIndex(index);
        await settleUntil(
          () => rig.handler.playbackState.value.queueIndex == index,
        );
      }

      // Deuxième expiration (~30 min) : AVANT la correction, le verrou « une
      // récupération par file » refusait le refresh et la musique s'arrêtait.
      rig.clock.advance(const Duration(minutes: 15));
      rig.player.emitError(authError());
      await settleUntil(() => rig.player.setAudioSourcesCalls == 3);
      expect(rig.refreshLog.length, 2);
      expect(rig.player.lastHeaders?['Authorization'], 'Bearer renewed-2');
      expect(
        rig.handler.playbackState.value.processingState,
        isNot(AudioProcessingState.error),
      );
    },
  );

  test(
    'anti-boucle : un second 401 immédiat ne martèle pas le refresh',
    () async {
      final rig = makeRig();
      await rig.handler.setQueueAndPlay(items: makeQueue(5), initialIndex: 0);
      await settleUntil(() => rig.player.playCalls == 1);

      rig.player.emitError(authError());
      await settleUntil(() => rig.refreshLog.length == 1);
      await settleUntil(() => rig.player.setAudioSourcesCalls == 2);

      // Le serveur répond 401 en continu (session révoquée) : sans progression
      // d'horloge, aucune nouvelle tentative — l'échec devient visible.
      rig.player.suppressReadyOnPlay = true;
      rig.player.emitError(authError());
      await settleUntil(
        () =>
            rig.handler.playbackState.value.processingState ==
            AudioProcessingState.error,
      );
      expect(rig.refreshLog.length, 1);
    },
  );

  test(
    'un refresh impossible aboutit à une erreur visible, sans boucle',
    () async {
      final rig = makeRig(refreshResult: 0); // tout refresh échoue
      await rig.handler.setQueueAndPlay(items: makeQueue(5), initialIndex: 0);
      await settleUntil(() => rig.player.playCalls == 1);

      rig.player.emitError(authError());
      await settleUntil(
        () =>
            rig.handler.playbackState.value.processingState ==
            AudioProcessingState.error,
      );
      expect(rig.refreshLog.length, 1);
      expect(rig.player.setAudioSourcesCalls, 1);
      expect(rig.handler.playbackState.value.errorMessage, isNotNull);
    },
  );

  test('le saut après erreur suit l’ordre shuffle effectif', () async {
    final rig = makeRig();
    await rig.handler.setQueueAndPlay(items: makeQueue(6), initialIndex: 0);
    await settleUntil(() => rig.player.playCalls == 1);
    rig.player.shuffleOrder = const [0, 3, 1, 5, 2, 4];
    await rig.handler.setShuffleMode(AudioServiceShuffleMode.all);

    rig.player.emitError(sourceError());
    await settleUntil(() => rig.player.setAudioSourcesCalls == 2);
    // Après l'index 0, l'ordre shuffle passe à 3.
    expect(rig.player.lastInitialIndex, 3);
  });

  test('une queue remplacée pendant la récupération est respectée', () async {
    final rig = makeRig();
    await rig.handler.setQueueAndPlay(items: makeQueue(10), initialIndex: 0);
    await settleUntil(() => rig.player.playCalls == 1);

    rig.player.emitError(sourceError());
    // Remplacement immédiat par une nouvelle file : l'ancienne récupération
    // ne doit pas écraser la nouvelle demande.
    await rig.handler.setQueueAndPlay(items: makeQueue(3), initialIndex: 2);
    await settleUntil(() => rig.handler.queue.value.length == 3);
    expect(rig.handler.queue.value.length, 3);
    expect(
      rig.handler.playbackState.value.processingState,
      isNot(AudioProcessingState.error),
    );
  });
}

class _FakeClock {
  DateTime _now = DateTime(2026, 7, 16, 12);

  DateTime now() => _now;

  void advance(Duration delta) => _now = _now.add(delta);
}

/// Faux lecteur pilotable : séquence native, avancement d'index, erreurs de
/// source, ordre shuffle. Reprend le contrat utilisé par le handler.
class _LongSessionFakePlayer implements AudioPlayer {
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

  int setAudioSourcesCalls = 0;
  int playCalls = 0;
  int? lastInitialIndex;
  Map<String, String>? lastHeaders;
  Duration? loadedDuration = const Duration(minutes: 3);
  bool suppressReadyOnPlay = false;
  List<int> shuffleOrder = const <int>[];

  List<IndexedAudioSource> _sequence = const [];
  int? _currentIndex;
  double _speed = 1;
  double _pitch = 1;
  double _volume = 1;
  bool _playing = false;
  bool _shuffleEnabled = false;
  ProcessingState _processingState = ProcessingState.idle;

  PlaybackEvent get _event => PlaybackEvent(
    processingState: _processingState,
    currentIndex: _currentIndex,
    duration: loadedDuration,
  );

  void _broadcast() {
    _events.add(_event);
    _states.add(PlayerState(_playing, _processingState));
  }

  /// Simule l'avancement automatique natif vers [index].
  void advanceToIndex(int index) {
    _currentIndex = index;
    _indexes.add(index);
    _processingState = ProcessingState.ready;
    _broadcast();
  }

  /// Simule la fin naturelle de la dernière piste.
  void completeQueue() {
    _processingState = ProcessingState.completed;
    _playing = false;
    _broadcast();
  }

  /// Simule une erreur de source native : le lecteur repasse idle (comme le
  /// fork après onPlayerError) et l'erreur part sur playbackEventStream.
  void emitError(PlayerException exception) {
    _processingState = ProcessingState.idle;
    _playing = false;
    _events.addError(exception, StackTrace.current);
    _states.add(PlayerState(false, ProcessingState.idle));
  }

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
        return loadedDuration;
      case #processingState:
        return _processingState;
      case #currentIndex:
        return _currentIndex;
      case #sequence:
        return _sequence;
      case #playing:
        return _playing;
      case #speed:
        return _speed;
      case #pitch:
        return _pitch;
      case #volume:
        return _volume;
      case #shuffleModeEnabled:
        return _shuffleEnabled;
      case #shuffleIndices:
        return shuffleOrder.isEmpty
            ? List<int>.generate(_sequence.length, (i) => i)
            : shuffleOrder;
      case #setVolume:
        _volume = invocation.positionalArguments.first as double;
        _volumes.add(_volume);
        return Future<void>.value();
      case #setSpeed:
        _speed = invocation.positionalArguments.first as double;
        return Future<void>.value();
      case #setPitch:
        _pitch = invocation.positionalArguments.first as double;
        return Future<void>.value();
      case #setShuffleModeEnabled:
        _shuffleEnabled = invocation.positionalArguments.first as bool;
        return Future<void>.value();
      case #shuffle:
        return Future<void>.value();
      case #setLoopMode:
        return Future<void>.value();
      case #setAudioSources:
        setAudioSourcesCalls += 1;
        final sources = invocation.positionalArguments.first as List;
        _sequence = sources.cast<IndexedAudioSource>();
        lastInitialIndex =
            invocation.namedArguments[#initialIndex] as int? ?? 0;
        if (_sequence.isNotEmpty) {
          final first =
              _sequence[lastInitialIndex!.clamp(0, _sequence.length - 1)];
          if (first is UriAudioSource) {
            lastHeaders = first.headers?.cast<String, String>();
          }
        }
        _currentIndex = _sequence.isEmpty ? null : lastInitialIndex;
        _processingState = _sequence.isEmpty
            ? ProcessingState.idle
            : ProcessingState.ready;
        if (_currentIndex != null) _indexes.add(_currentIndex);
        _broadcast();
        return Future<Duration?>.value(loadedDuration);
      case #pause:
        _playing = false;
        _states.add(PlayerState(false, _processingState));
        return Future<void>.value();
      case #stop:
        _playing = false;
        _processingState = ProcessingState.idle;
        _broadcast();
        return Future<void>.value();
      case #play:
        playCalls += 1;
        _playing = true;
        if (!suppressReadyOnPlay) {
          _processingState = ProcessingState.ready;
        }
        _broadcast();
        return Future<void>.value();
      case #seek:
        final index = invocation.namedArguments[#index] as int?;
        if (index != null) {
          _currentIndex = index;
          _indexes.add(index);
        }
        _broadcast();
        return Future<void>.value();
      case #dispose:
        _events.close();
        _states.close();
        _indexes.close();
        _positions.close();
        _buffered.close();
        _durations.close();
        _volumes.close();
        return Future<void>.value();
      default:
        return super.noSuchMethod(invocation);
    }
  }
}
