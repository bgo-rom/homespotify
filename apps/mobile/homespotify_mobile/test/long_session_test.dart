import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

import 'package:homespotify_mobile/src/features/player/audio/audio_diagnostics.dart';
import 'package:homespotify_mobile/src/features/player/audio/homespotify_audio_handler.dart';
import 'package:homespotify_mobile/src/features/player/data/playback_session_store.dart';

/// Fiabilité des longues sessions : une file de 200 pistes doit rester cohérente
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

  List<PlayerQueueItem> makeQueue(
    int count, {
    int? userId,
    bool withLocalFallback = false,
  }) => [
    for (var index = 0; index < count; index++)
      PlayerQueueItem(
        id: '${index + 1}',
        userId: userId,
        streamUri: Uri.parse('https://homespotify.test/${index + 1}/stream'),
        networkStreamUri: Uri.parse(
          'https://homespotify.test/${index + 1}/stream',
        ),
        localFallbackUri: withLocalFallback
            ? Uri.file('C:/offline/${index + 1}.ogg')
            : null,
        localFallbackMimeType: withLocalFallback ? 'audio/ogg' : null,
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
    void Function() rotateAuthorization,
  })
  makeRig({
    int refreshResult = -1,
    PlaybackSessionStore? playbackSessionStore,
    Duration endOfTrackGracePeriod = const Duration(seconds: 2),
    Duration playbackGuardInterval = const Duration(seconds: 1),
    Timer Function(Duration, void Function())? sleepTimerFactory,
  }) {
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
      playbackSessionStore: playbackSessionStore,
      endOfTrackGracePeriod: endOfTrackGracePeriod,
      playbackGuardInterval: playbackGuardInterval,
      sleepTimerFactory: sleepTimerFactory,
    );
    addTearDown(handler.dispose);
    return (
      player: player,
      handler: handler,
      clock: clock,
      refreshLog: refreshLog,
      rotateAuthorization: () => tokenGeneration += 1,
    );
  }

  test(
    'l’atténuation ReplayGain reste séparée du volume utilisateur',
    () async {
      final rig = makeRig();

      await rig.handler.setVolume(0.8);
      await rig.handler.setReplayGainAttenuationDb(-6);

      expect(rig.handler.volume, 0.8);
      expect(rig.player.volume, closeTo(0.40095, 0.001));

      await rig.handler.setReplayGainAttenuationDb(null);
      expect(rig.handler.volume, 0.8);
      expect(rig.player.volume, closeTo(0.8, 0.001));
    },
  );

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

  test('une file de 200 pistes reste alignée jusqu’au dernier index', () async {
    final rig = makeRig();
    await rig.handler.setQueueAndPlay(items: makeQueue(200), initialIndex: 0);
    await settleUntil(() => rig.player.playCalls == 1);

    expect(rig.handler.queue.value.length, 200);
    expect(rig.player.sequence.length, 200);
    for (final index in <int>[1, 49, 99, 149, 199]) {
      rig.player.advanceToIndex(index);
      await settleUntil(
        () => rig.handler.playbackState.value.queueIndex == index,
      );
      expect(rig.handler.mediaItem.value?.id, '${index + 1}');
      expect(
        rig.handler.playbackState.value.processingState,
        isNot(AudioProcessingState.error),
      );
    }
    expect(rig.player.setAudioSourcesCalls, 1);
  });

  test('le minuteur temporisé met en pause et conserve la file', () async {
    _ManualTimer? timer;
    final rig = makeRig(
      sleepTimerFactory: (duration, callback) {
        timer = _ManualTimer(callback);
        return timer!;
      },
    );
    await rig.handler.setQueueAndPlay(items: makeQueue(4), initialIndex: 1);
    await settleUntil(() => rig.player.playCalls == 1);

    rig.handler.armSleepTimer(const Duration(minutes: 30));
    expect(rig.handler.sleepTimerState.mode, SleepTimerMode.timed);
    expect(rig.handler.sleepTimerState.isActive, isTrue);
    timer!.fire();
    await settleUntil(() => !rig.player.playing);

    expect(rig.handler.sleepTimerState.mode, SleepTimerMode.off);
    expect(rig.handler.queue.value.length, 4);
    expect(rig.player.currentIndex, 1);
    expect(
      AudioDiagnostics.instance.snapshot().join('\n'),
      contains('AUDIO_SLEEP_TIMER_EXPIRED'),
    );
  });

  test(
    'fin du titre empêche le démarrage durable de la piste suivante',
    () async {
      final rig = makeRig();
      await rig.handler.setQueueAndPlay(items: makeQueue(3), initialIndex: 0);
      await settleUntil(() => rig.player.playCalls == 1);

      rig.handler.armSleepTimerAtEndOfTrack();
      expect(rig.handler.sleepTimerState.mode, SleepTimerMode.endOfTrack);
      rig.player.advanceToIndex(1);
      await settleUntil(() => !rig.player.playing);

      expect(rig.handler.sleepTimerState.mode, SleepTimerMode.off);
      expect(rig.player.currentIndex, 1);
      expect(rig.player.playCalls, 1);
    },
  );

  test('annuler le minuteur neutralise son callback', () async {
    _ManualTimer? timer;
    final rig = makeRig(
      sleepTimerFactory: (duration, callback) {
        timer = _ManualTimer(callback);
        return timer!;
      },
    );
    await rig.handler.setQueueAndPlay(items: makeQueue(2), initialIndex: 0);
    await settleUntil(() => rig.player.playCalls == 1);

    rig.handler.armSleepTimer(const Duration(minutes: 15));
    rig.handler.cancelSleepTimer();
    timer!.fire();
    await settleUntil(() => rig.player.playing);

    expect(rig.handler.sleepTimerState.mode, SleepTimerMode.off);
    expect(rig.player.playing, isTrue);
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

  test('la file et ses modes sont persistés puis restaurés en pause', () async {
    final store = _MemoryPlaybackSessionStore();
    final first = makeRig(playbackSessionStore: store);
    await first.handler.setQueueAndPlay(
      items: makeQueue(4, userId: 7),
      initialIndex: 2,
    );
    await settleUntil(() => first.player.playCalls == 1);
    await first.handler.seek(const Duration(seconds: 42));
    await first.handler.setRepeatMode(AudioServiceRepeatMode.all);
    await first.handler.setShuffleMode(AudioServiceShuffleMode.all);
    await first.handler.pause();
    await settleUntil(() => store.sessions[7]?.positionMs == 42000);

    final persisted = store.sessions[7];
    expect(persisted, isNotNull);
    expect(persisted!.currentIndex, 2);
    expect(persisted.repeatMode, 'all');
    expect(persisted.shuffleEnabled, isTrue);
    expect(persisted.wasPlaying, isFalse);
    expect(persisted.queue.length, 4);

    final restored = makeRig(playbackSessionStore: store);
    expect(await restored.handler.restorePlaybackSessionForUser(7), isTrue);
    expect(restored.player.lastInitialIndex, 2);
    expect(restored.player.lastInitialPosition, const Duration(seconds: 42));
    expect(restored.player.shuffleModeEnabled, isTrue);
    expect(restored.player.playing, isFalse);
    expect(restored.handler.queue.value.map((item) => item.id), [
      '1',
      '2',
      '3',
      '4',
    ]);
  });

  test('la restauration choisit la source adaptée au réseau courant', () async {
    final store = _MemoryPlaybackSessionStore();
    final initial = makeRig(playbackSessionStore: store);
    final networkUri = Uri.parse('https://homespotify.test/1/stream');
    final localUri = Uri.file('C:/offline/1.ogg');
    await initial.handler.setQueueAndPlay(
      items: [
        PlayerQueueItem(
          id: '1',
          userId: 7,
          streamUri: localUri,
          networkStreamUri: networkUri,
          localFallbackUri: localUri,
          localFallbackMimeType: 'audio/ogg',
          title: 'Piste',
        ),
      ],
      initialIndex: 0,
    );
    await initial.handler.pause();
    await settleUntil(() => store.sessions[7] != null);

    final online = makeRig(playbackSessionStore: store);
    expect(await online.handler.restorePlaybackSessionForUser(7), isTrue);
    expect(online.player.lastUri, networkUri);

    final offline = makeRig(playbackSessionStore: store);
    await offline.handler.handleConnectivityChanged(false);
    expect(await offline.handler.restorePlaybackSessionForUser(7), isTrue);
    expect(offline.player.lastUri, localUri);
    expect(offline.player.lastHeaders, isNull);
  });

  test(
    'une coupure réseau reprend la même piste et la même position',
    () async {
      final rig = makeRig();
      await rig.handler.setQueueAndPlay(items: makeQueue(6), initialIndex: 0);
      await settleUntil(() => rig.player.playCalls == 1);
      rig.player.advanceToIndex(3);
      await rig.handler.seek(const Duration(seconds: 42));
      await rig.handler.handleConnectivityChanged(false);

      rig.player.emitError(sourceError('SocketException: network unreachable'));
      await settleUntil(
        () =>
            rig.handler.playbackState.value.processingState ==
            AudioProcessingState.buffering,
      );
      expect(rig.player.setAudioSourcesCalls, 1);

      await rig.handler.handleConnectivityChanged(true);
      await settleUntil(() => rig.player.setAudioSourcesCalls == 2);
      expect(rig.player.lastInitialIndex, 3);
      expect(rig.player.lastInitialPosition, const Duration(seconds: 42));
      await settleUntil(() => rig.player.playCalls >= 2);
      expect(
        rig.handler.playbackState.value.processingState,
        isNot(AudioProcessingState.error),
      );
    },
  );

  test(
    'une coupure réseau bascule sur la copie locale au même index et position',
    () async {
      final rig = makeRig();
      await rig.handler.setQueueAndPlay(
        items: makeQueue(6, withLocalFallback: true),
        initialIndex: 3,
      );
      await settleUntil(() => rig.player.playCalls == 1);
      await rig.handler.seek(const Duration(seconds: 42));

      await rig.handler.handleConnectivityChanged(false);
      rig.player.emitError(sourceError('SocketException: network unreachable'));
      await settleUntil(() => rig.player.setAudioSourcesCalls == 2);
      await settleUntil(() => rig.player.playCalls >= 2);

      expect(rig.player.lastInitialIndex, 3);
      expect(rig.player.lastInitialPosition, const Duration(seconds: 42));
      expect(rig.player.lastUri?.scheme, 'file');
      expect(rig.player.lastHeaders, isNull);
      expect(rig.handler.mediaItem.value?.extras?['source'], 'local');
      expect(
        AudioDiagnostics.instance.snapshot().join('\n'),
        contains('AUDIO_LOCAL_FALLBACK_COMPLETED'),
      );
    },
  );

  test(
    'après retour réseau le titre local finit puis le suivant reprend en ligne',
    () async {
      final rig = makeRig();
      await rig.handler.setQueueAndPlay(
        items: makeQueue(4, withLocalFallback: true),
        initialIndex: 0,
      );
      await settleUntil(() => rig.player.playCalls == 1);
      await rig.handler.handleConnectivityChanged(false);
      rig.player.emitError(sourceError('SocketException: network unreachable'));
      await settleUntil(() => rig.player.setAudioSourcesCalls == 2);

      await rig.handler.handleConnectivityChanged(true);
      expect(rig.player.setAudioSourcesCalls, 2);
      expect(rig.player.lastUri?.scheme, 'file');

      rig.player.advanceToIndex(1);
      await settleUntil(() => rig.player.setAudioSourcesCalls == 3);
      await settleUntil(() => rig.player.playCalls >= 3);
      expect(rig.player.lastInitialIndex, 1);
      expect(rig.player.lastUri?.scheme, 'https');
      expect(
        AudioDiagnostics.instance.snapshot().join('\n'),
        contains('AUDIO_NETWORK_SOURCE_RESTORE_COMPLETED'),
      );
    },
  );

  test('une copie locale illisible retombe sur le réseau sans saut', () async {
    final networkUri = Uri.parse('https://homespotify.test/1/stream');
    final rig = makeRig();
    await rig.handler.setQueueAndPlay(
      items: [
        PlayerQueueItem(
          id: '1',
          streamUri: Uri.file('C:/offline/1.ogg'),
          networkStreamUri: networkUri,
          localFallbackUri: Uri.file('C:/offline/1.ogg'),
          localFallbackMimeType: 'audio/ogg',
          title: 'Piste locale',
          headers: const {'Authorization': 'Bearer initial'},
        ),
      ],
      initialIndex: 0,
    );
    await settleUntil(() => rig.player.playCalls == 1);

    rig.player.emitError(sourceError());
    await settleUntil(() => rig.player.setAudioSourcesCalls == 2);
    await settleUntil(() => rig.player.playCalls >= 2);
    expect(rig.player.lastInitialIndex, 0);
    expect(rig.player.lastUri, networkUri);
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

      // Troisième expiration simulée (~45 min) : le verrou est relâché après
      // chaque récupération réussie et la file reste sur la piste courante.
      rig.clock.advance(const Duration(minutes: 15));
      rig.player.emitError(authError());
      await settleUntil(() => rig.player.setAudioSourcesCalls == 4);
      expect(rig.refreshLog.length, 3);
      expect(rig.player.lastInitialIndex, 9);
      expect(rig.player.lastHeaders?['Authorization'], 'Bearer renewed-3');
      expect(
        rig.handler.playbackState.value.processingState,
        isNot(AudioProcessingState.error),
      );
    },
  );

  test(
    'un token renouvelé en amont reconstruit la source sans double refresh',
    () async {
      final rig = makeRig();
      await rig.handler.setQueueAndPlay(items: makeQueue(5), initialIndex: 0);
      await settleUntil(() => rig.player.playCalls == 1);

      // Le timer de session a déjà fait tourner le token, mais Media3 conserve
      // le Bearer figé dans la source créée avant ce renouvellement.
      rig.rotateAuthorization();
      rig.player.emitError(authError());
      await settleUntil(() => rig.player.setAudioSourcesCalls == 2);

      expect(rig.refreshLog, isEmpty);
      expect(rig.player.lastHeaders?['Authorization'], 'Bearer renewed-1');
      await settleUntil(() => rig.player.playCalls >= 2);
      expect(
        rig.handler.playbackState.value.processingState,
        isNot(AudioProcessingState.error),
      );
    },
  );

  test(
    'un Source error générique utilise le token déjà tourné sans sauter',
    () async {
      final rig = makeRig();
      await rig.handler.setQueueAndPlay(items: makeQueue(5), initialIndex: 2);
      await settleUntil(() => rig.player.playCalls == 1);

      // Media3 ne conserve parfois que "Source error" et perd le code 401.
      // La rotation du Bearer suffit alors à identifier la récupération auth.
      rig.rotateAuthorization();
      rig.player.emitError(sourceError());
      await settleUntil(() => rig.player.setAudioSourcesCalls == 2);

      expect(rig.refreshLog, isEmpty);
      expect(rig.player.lastInitialIndex, 2);
      expect(rig.player.lastHeaders?['Authorization'], 'Bearer renewed-1');
      await settleUntil(() => rig.player.playCalls >= 2);
      expect(
        rig.handler.playbackState.value.processingState,
        isNot(AudioProcessingState.error),
      );
    },
  );

  test('Lecture reconstruit une file idle avec le dernier Bearer', () async {
    final rig = makeRig();
    await rig.handler.setQueueAndPlay(items: makeQueue(1), initialIndex: 0);
    await settleUntil(() => rig.player.playCalls == 1);

    // Une file d'une piste ne peut pas sauter l'élément en erreur : elle
    // publie donc un échec visible et marque la source comme inutilisable.
    rig.player.emitError(sourceError());
    await settleUntil(
      () =>
          rig.handler.playbackState.value.processingState ==
          AudioProcessingState.error,
    );

    rig.rotateAuthorization();
    expect(
      await rig.handler.handleAuthorizationChanged(reason: 'idle-refresh'),
      isFalse,
    );
    await rig.handler.play();
    await settleUntil(() => rig.player.setAudioSourcesCalls == 2);
    await settleUntil(() => rig.player.playCalls >= 2);

    expect(rig.player.lastInitialIndex, 0);
    expect(rig.player.lastHeaders?['Authorization'], 'Bearer renewed-1');
    expect(
      rig.handler.playbackState.value.processingState,
      isNot(AudioProcessingState.error),
    );
  });

  test(
    'une rotation proactive est propagée avant tout 401, à position constante',
    () async {
      final rig = makeRig();
      await rig.handler.setQueueAndPlay(items: makeQueue(5), initialIndex: 0);
      await settleUntil(() => rig.player.playCalls == 1);
      rig.player.advanceToIndex(2);
      await rig.handler.seek(const Duration(seconds: 42));

      // Le timer auth renouvelle le JWT 90 secondes avant son expiration.
      // Le lecteur doit reconstruire immédiatement les AudioSource dont les
      // headers sont immuables, sans attendre que Media3 rencontre un 401.
      rig.rotateAuthorization();
      expect(
        await rig.handler.handleAuthorizationChanged(reason: 'test-refresh'),
        isTrue,
      );

      expect(rig.refreshLog, isEmpty);
      expect(rig.player.setAudioSourcesCalls, 2);
      expect(rig.player.lastInitialIndex, 2);
      expect(rig.player.lastInitialPosition, const Duration(seconds: 42));
      expect(rig.player.lastHeaders?['Authorization'], 'Bearer renewed-1');
      await settleUntil(() => rig.player.playCalls >= 2);
      expect(
        rig.handler.playbackState.value.processingState,
        isNot(AudioProcessingState.error),
      );
    },
  );

  test(
    'les rotations proactives répétées maintiennent la session sans limite',
    () async {
      final rig = makeRig();
      await rig.handler.setQueueAndPlay(items: makeQueue(20), initialIndex: 0);
      await settleUntil(() => rig.player.playCalls == 1);

      for (var generation = 1; generation <= 5; generation++) {
        rig.rotateAuthorization();
        expect(
          await rig.handler.handleAuthorizationChanged(
            reason: 'test-refresh-$generation',
          ),
          isTrue,
        );
        expect(rig.player.setAudioSourcesCalls, generation + 1);
        expect(
          rig.player.lastHeaders?['Authorization'],
          'Bearer renewed-$generation',
        );
      }

      expect(rig.refreshLog, isEmpty);
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

  test(
    'la même erreur native remontée deux fois ne déclenche qu’une recovery',
    () async {
      final rig = makeRig();
      await rig.handler.setQueueAndPlay(items: makeQueue(6), initialIndex: 0);
      await settleUntil(() => rig.player.playCalls == 1);

      final blocker = Completer<void>();
      rig.player.nextSetAudioSourcesBlocker = blocker;
      final error = sourceError(
        'InvalidResponseCodeException: Response code: 404',
      );
      rig.player.emitError(error);
      rig.player.emitError(error);
      await settleUntil(() => rig.player.setAudioSourcesCalls == 2);

      expect(rig.player.setAudioSourcesCalls, 2);
      expect(
        AudioDiagnostics.instance.snapshot().join('\n'),
        contains('AUDIO_DUPLICATE_ERROR_SUPPRESSED'),
      );
      blocker.complete();
      await settleUntil(() => rig.player.playCalls >= 2);
      expect(rig.player.lastInitialIndex, 1);
    },
  );

  test(
    'un completed prématuré avant la fin déclenche un seul auto-advance borné',
    () async {
      final rig = makeRig();
      await rig.handler.setQueueAndPlay(items: makeQueue(3), initialIndex: 0);
      await settleUntil(() => rig.player.playCalls == 1);

      rig.player.completeQueue();
      await settleUntil(() => rig.player.currentIndex == 1);
      await settleUntil(() => rig.player.playCalls == 2);

      expect(rig.player.currentIndex, 1);
      expect(rig.player.playCalls, 2);
      expect(
        AudioDiagnostics.instance.snapshot().join('\n'),
        contains('AUDIO_QUEUE_AUTO_ADVANCE_COMPLETED'),
      );
    },
  );

  test(
    'playing bloqué à la durée avance même sans état completed natif',
    () async {
      final rig = makeRig(endOfTrackGracePeriod: Duration.zero);
      await rig.handler.setQueueAndPlay(items: makeQueue(3), initialIndex: 0);
      await settleUntil(() => rig.player.playCalls == 1);

      // Incident réel Android : position == durée et playing=true, mais le
      // moteur reste en ready au lieu d'émettre completed/index suivant.
      rig.player.stallAtEnd();
      await settleUntil(() => rig.player.currentIndex == 1);
      await settleUntil(() => rig.player.playCalls == 2);

      expect(rig.player.currentIndex, 1);
      expect(rig.player.playCalls, 2);
      expect(
        AudioDiagnostics.instance.snapshot().join('\n'),
        contains('AUDIO_END_OF_TRACK_STALL_DETECTED'),
      );
      expect(
        AudioDiagnostics.instance.snapshot().join('\n'),
        contains('position-stalled-at-logical-end'),
      );
    },
  );

  test(
    'le garde périodique avance si le flux de position cesse à la fin',
    () async {
      final rig = makeRig(
        endOfTrackGracePeriod: Duration.zero,
        playbackGuardInterval: const Duration(milliseconds: 10),
      );
      await rig.handler.setQueueAndPlay(items: makeQueue(3), initialIndex: 0);
      await settleUntil(() => rig.player.playCalls == 1);

      rig.player.stallAtEndSilently();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await settleUntil(() => rig.player.currentIndex == 1);

      expect(rig.player.currentIndex, 1);
      expect(
        AudioDiagnostics.instance.snapshot().join('\n'),
        contains('AUDIO_END_OF_TRACK_STALL_DETECTED'),
      );
    },
  );

  test(
    'un retour natif de la fin vers zéro ne reboucle pas la même piste',
    () async {
      final rig = makeRig(
        endOfTrackGracePeriod: const Duration(seconds: 2),
        playbackGuardInterval: const Duration(milliseconds: 10),
      );
      await rig.handler.setQueueAndPlay(items: makeQueue(3), initialIndex: 0);
      await settleUntil(() => rig.player.playCalls == 1);

      rig.player.approachEnd();
      await settleUntil(
        () => AudioDiagnostics.instance.snapshot().join('\n').isNotEmpty,
      );
      rig.player.wrapToStartSilently();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await settleUntil(() => rig.player.currentIndex == 1);

      expect(rig.player.currentIndex, 1);
      expect(
        AudioDiagnostics.instance.snapshot().join('\n'),
        contains('AUDIO_END_OF_TRACK_POSITION_WRAPPED'),
      );
    },
  );
}

class _ManualTimer implements Timer {
  _ManualTimer(this._callback);

  final void Function() _callback;
  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  int get tick => _active ? 0 : 1;

  @override
  void cancel() {
    _active = false;
  }

  void fire() {
    if (!_active) return;
    _active = false;
    _callback();
  }
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
  Duration? lastInitialPosition;
  Uri? lastUri;
  Map<String, String>? lastHeaders;
  Duration? loadedDuration = const Duration(minutes: 3);
  bool suppressReadyOnPlay = false;
  Completer<void>? nextSetAudioSourcesBlocker;
  List<int> shuffleOrder = const <int>[];

  List<IndexedAudioSource> _sequence = const [];
  int? _currentIndex;
  double _speed = 1;
  double _pitch = 1;
  double _volume = 1;
  Duration _position = Duration.zero;
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

  /// Simule Media3 bloqué à la fin : la timeline est terminée, mais l'état
  /// reste ready/playing et aucun nouvel index n'est publié.
  void stallAtEnd() {
    _position = loadedDuration ?? Duration.zero;
    _processingState = ProcessingState.ready;
    _playing = true;
    _positions.add(_position);
    _broadcast();
  }

  void stallAtEndSilently() {
    _position = loadedDuration ?? Duration.zero;
    _processingState = ProcessingState.ready;
    _playing = true;
  }

  void approachEnd() {
    final durationMs = (loadedDuration ?? Duration.zero).inMilliseconds;
    _position = Duration(milliseconds: (durationMs * 0.95).round());
    _positions.add(_position);
  }

  void wrapToStartSilently() {
    _position = Duration.zero;
    _processingState = ProcessingState.ready;
    _playing = true;
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
        return _position;
      case #bufferedPosition:
        return _position;
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
        lastInitialPosition =
            invocation.namedArguments[#initialPosition] as Duration? ??
            Duration.zero;
        if (_sequence.isNotEmpty) {
          final first =
              _sequence[lastInitialIndex!.clamp(0, _sequence.length - 1)];
          if (first is UriAudioSource) {
            lastUri = first.uri;
            lastHeaders = first.headers?.cast<String, String>();
          }
        }
        Future<Duration?> completeLoad() {
          _currentIndex = _sequence.isEmpty ? null : lastInitialIndex;
          _position = lastInitialPosition ?? Duration.zero;
          _positions.add(_position);
          _processingState = _sequence.isEmpty
              ? ProcessingState.idle
              : ProcessingState.ready;
          if (_currentIndex != null) _indexes.add(_currentIndex);
          _broadcast();
          return Future<Duration?>.value(loadedDuration);
        }
        final blocker = nextSetAudioSourcesBlocker;
        nextSetAudioSourcesBlocker = null;
        if (blocker != null) {
          return blocker.future.then((_) => completeLoad());
        }
        return completeLoad();
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
        _position = invocation.positionalArguments.first as Duration;
        _positions.add(_position);
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

class _MemoryPlaybackSessionStore implements PlaybackSessionStore {
  final Map<int, PersistedPlaybackSession> sessions = {};

  @override
  Future<void> delete(int userId) async {
    sessions.remove(userId);
  }

  @override
  Future<PersistedPlaybackSession?> read(int userId) async => sessions[userId];

  @override
  Future<void> write(PersistedPlaybackSession session) async {
    sessions[session.userId] = session;
  }
}
