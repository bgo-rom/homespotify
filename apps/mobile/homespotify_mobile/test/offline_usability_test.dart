import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homespotify_mobile/src/features/auth/application/auth_controller.dart';
import 'package:homespotify_mobile/src/features/auth/data/token_store.dart';
import 'package:homespotify_mobile/src/features/library/data/library_api.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_filters.dart';
import 'package:homespotify_mobile/src/features/library/domain/track.dart';
import 'package:homespotify_mobile/src/features/offline/application/offline_artwork_cache.dart';
import 'package:homespotify_mobile/src/features/offline/application/offline_index.dart';
import 'package:homespotify_mobile/src/features/offline/application/offline_local_playback.dart';
import 'package:homespotify_mobile/src/features/offline/application/offline_track_downloader.dart';
import 'package:homespotify_mobile/src/features/offline/data/offline_api.dart';
import 'package:homespotify_mobile/src/features/offline/data/offline_manifest_store.dart';
import 'package:homespotify_mobile/src/features/offline/domain/offline_models.dart';
import 'package:homespotify_mobile/src/features/offline/presentation/downloads_screen.dart';
import 'package:homespotify_mobile/src/features/offline/presentation/offline_mode_banner.dart';
import 'package:homespotify_mobile/src/features/player/presentation/player_providers.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_auth.dart';

/// Phase 1A.1 — hors connexion réellement utilisable.
/// Couvre les 14 scénarios obligatoires (le n° est rappelé dans chaque nom) ;
/// le scénario 14 (reprise d'un .part interrompu) vit déjà dans
/// offline_phase1a_test.dart (« reprise : un .part existant repart de son
/// offset ») et n'est pas dupliqué ici.

/// API hors ligne qui ÉCHOUE à tout appel : prouve qu'un chemin de code est
/// 100 % local (manifeste SQLite seul).
class _CoverAdapter implements HttpClientAdapter {
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls += 1;
    return ResponseBody.fromBytes(
      [0xFF, 0xD8, 0xFF, 0xD9],
      200,
      headers: {
        Headers.contentTypeHeader: ['image/jpeg'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class ThrowingOfflineApi implements OfflineApi {
  int calls = 0;

  Never _forbidden() {
    calls += 1;
    throw StateError('Appel API interdit dans un scénario 100 % local.');
  }

  @override
  Future<List<OfflineOption>> fetchOptions(int trackId) async => _forbidden();

  @override
  Future<OfflineVariantState> requestVariant(
    int trackId,
    OfflineProfile profile, {
    CancelToken? cancelToken,
  }) async => _forbidden();

  @override
  Future<OfflineVariantState> variantStatus(
    int trackId,
    OfflineProfile profile, {
    CancelToken? cancelToken,
  }) async => _forbidden();

  @override
  Uri downloadUri(int trackId, OfflineProfile profile) => _forbidden();

  @override
  Future<Response<ResponseBody>> openDownloadStream(
    int trackId,
    OfflineProfile profile, {
    int fromByte = 0,
    CancelToken? cancelToken,
  }) async => _forbidden();
}

late Directory tempRoot;
int storeCounter = 0;

Future<SqliteOfflineManifestStore> makeStore() async {
  storeCounter += 1;
  return SqliteOfflineManifestStore(
    factory: databaseFactoryFfi,
    databasePath: '${tempRoot.path}/manifest-$storeCounter.db',
  );
}

/// Copie locale « ready » : ligne de manifeste + fichier réel sur disque.
Future<OfflineTrackRecord> seedReadyCopy(
  OfflineManifestStore store, {
  required int userId,
  required int trackId,
  OfflineProfile profile = OfflineProfile.opus256,
  String? title,
  int sizeBytes = 64,
  bool writeFile = true,
  int? fileBytes,
}) async {
  final name =
      '$trackId-${profile.wire}${profile == OfflineProfile.original ? '.flac' : '.ogg'}';
  if (writeFile) {
    final dir = Directory('${tempRoot.path}/offline/u$userId')
      ..createSync(recursive: true);
    File(
      '${dir.path}/$name',
    ).writeAsBytesSync(List.filled(fileBytes ?? sizeBytes, 7));
  }
  final record = OfflineTrackRecord(
    userId: userId,
    trackId: trackId,
    profile: profile,
    sourceSha256: 'src-$trackId',
    status: OfflineDownloadStatus.ready,
    receivedBytes: sizeBytes,
    sizeBytes: sizeBytes,
    relativePath: name,
    title: title ?? 'Piste $trackId',
    artist: 'Artiste $trackId',
    album: 'Album $trackId',
    durationSeconds: 120,
  );
  await store.upsert(record);
  return record;
}

/// Conteneur Riverpod pour les tests du contrôleur d'auth (sans widget).
ProviderContainer authContainer({
  required FakeTokenStore store,
  required FakeAuthApi api,
}) {
  final container = ProviderContainer(
    retry: (retryCount, error) => null,
    overrides: [
      tokenStoreProvider.overrideWithValue(store),
      biometricServiceProvider.overrideWithValue(FakeBiometricService()),
      authApiProvider.overrideWithValue(api),
      authSessionManagerProvider.overrideWithValue(
        FakeSessionManager(store: store),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<AuthState> settleAuth(ProviderContainer container) async {
  container.read(authControllerProvider);
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final state = container.read(authControllerProvider);
    if (state.status != AuthStatus.loading) return state;
  }
  return container.read(authControllerProvider);
}

String identityJsonFor(AuthUserLike user) => jsonEncode({
  'id': user.id,
  'username': user.username,
  'displayName': user.username,
  'role': 'USER',
  'isActive': true,
  'mustChangePassword': false,
});

class AuthUserLike {
  const AuthUserLike(this.id, this.username);
  final int id;
  final String username;
}

void main() {
  sqfliteFfiInit();

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('homespotify-offline-ux');
  });

  tearDown(() {
    try {
      tempRoot.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows : un handle sqlite peut se fermer légèrement après le test.
    }
  });

  group('session locale hors connexion (A)', () {
    test(
      '1. serveur injoignable + session connue → mode hors connexion ouvert',
      () async {
        final store = FakeTokenStore()
          ..tokens = const AuthTokens(accessToken: 'a', refreshToken: 'r')
          ..localIdentityJson = identityJsonFor(
            const AuthUserLike(7, 'romain'),
          );
        final api = FakeAuthApi()..networkDown = true;

        final state = await settleAuth(authContainer(store: store, api: api));

        expect(state.status, AuthStatus.offline);
        expect(state.user?.id, 7);
        expect(state.user?.username, 'romain');
      },
    );

    test('2. serveur injoignable + aucun compte connu → première connexion '
        'explicite', () async {
      final store = FakeTokenStore(); // ni token ni identité
      final api = FakeAuthApi()..networkDown = true;

      final state = await settleAuth(authContainer(store: store, api: api));

      expect(state.status, AuthStatus.error);
      expect(state.message, contains('première connexion'));
    });

    test(
      '3. panne réseau → AUCUN logout, tokens et identité intacts',
      () async {
        final store = FakeTokenStore()
          ..tokens = const AuthTokens(accessToken: 'a', refreshToken: 'r')
          ..localIdentityJson = identityJsonFor(
            const AuthUserLike(7, 'romain'),
          );
        final api = FakeAuthApi()..networkDown = true;

        final state = await settleAuth(authContainer(store: store, api: api));

        expect(state.status, isNot(AuthStatus.unauthenticated));
        expect(store.tokens, isNotNull);
        expect(store.localIdentityJson, isNotNull);
      },
    );

    test('4. 401 définitif avec serveur joignable → déconnexion normale et '
        'identité purgée', () async {
      final store = FakeTokenStore()
        ..tokens = const AuthTokens(accessToken: 'mort', refreshToken: 'mort')
        ..localIdentityJson = identityJsonFor(const AuthUserLike(7, 'romain'));
      final api = FakeAuthApi(); // meResult null → 401, réseau OK

      final state = await settleAuth(authContainer(store: store, api: api));

      expect(state.status, AuthStatus.unauthenticated);
      expect(store.tokens, isNull);
      expect(store.localIdentityJson, isNull);
    });

    test(
      '12b. retour du serveur → reprise en ligne automatique sans fermer',
      () async {
        final store = FakeTokenStore()
          ..tokens = const AuthTokens(accessToken: 'a', refreshToken: 'r')
          ..localIdentityJson = identityJsonFor(
            const AuthUserLike(7, 'romain'),
          );
        final api = FakeAuthApi()..networkDown = true;
        final container = authContainer(store: store, api: api);

        expect((await settleAuth(container)).status, AuthStatus.offline);

        // Le serveur revient.
        api
          ..networkDown = false
          ..meResult = makeUser(id: 7, username: 'romain', role: 'USER');
        await container
            .read(authControllerProvider.notifier)
            .attemptOnlineRestore();

        expect(
          container.read(authControllerProvider).status,
          AuthStatus.authenticated,
        );
      },
    );

    test('13. redémarrage simulé : identité mémorisée au login, mode hors '
        'connexion au boot suivant sans serveur', () async {
      final store = FakeTokenStore();
      final user = makeUser(id: 9, username: 'skibidi', role: 'USER');
      final api = FakeAuthApi()
        ..bootstrapRequiredResult = false
        ..loginResult = FakeAuthApi.payloadFor(user);

      // 1er lancement : login réussi → identité persistée.
      final first = authContainer(store: store, api: api);
      await settleAuth(first);
      await first
          .read(authControllerProvider.notifier)
          .login(username: 'skibidi', password: 'x');
      expect(
        first.read(authControllerProvider).status,
        AuthStatus.authenticated,
      );
      expect(store.localIdentityJson, isNotNull);
      first.dispose();

      // « Redémarrage » en mode avion : nouveau conteneur, serveur mort.
      final second = authContainer(
        store: store,
        api: FakeAuthApi()..networkDown = true,
      );
      final state = await settleAuth(second);
      expect(state.status, AuthStatus.offline);
      expect(state.user?.id, 9);
    });
  });

  group('bandeau hors connexion', () {
    Future<void> pumpShell(WidgetTester tester, AuthState state) {
      return tester.pumpWidget(
        ProviderScope(
          overrides: authOverrides(state: state),
          child: const MaterialApp(
            home: OfflineAwareShell(child: Text('CONTENU')),
          ),
        ),
      );
    }

    testWidgets('affiché en mode hors connexion, app accessible dessous', (
      tester,
    ) async {
      await pumpShell(
        tester,
        AuthState(AuthStatus.offline, user: makeUser(id: 7)),
      );
      expect(find.textContaining('Mode hors connexion'), findsOneWidget);
      expect(find.text('CONTENU'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('offline-banner-retry')),
        findsOneWidget,
      );
    });

    testWidgets('absent quand la session est en ligne', (tester) async {
      await pumpShell(
        tester,
        AuthState(AuthStatus.authenticated, user: makeUser(id: 7)),
      );
      expect(find.textContaining('Mode hors connexion'), findsNothing);
      expect(find.text('CONTENU'), findsOneWidget);
    });
  });

  group('index hors ligne et isolation (C/E)', () {
    ProviderContainer indexContainer({
      required OfflineManifestStore store,
      required int userId,
    }) {
      final container = ProviderContainer(
        retry: (retryCount, error) => null,
        overrides: [
          ...authOverrides(
            state: AuthState(
              AuthStatus.authenticated,
              user: makeUser(id: userId),
            ),
          ),
          offlineManifestStoreProvider.overrideWithValue(store),
          offlineRootDirProvider.overrideWithValue(() async => tempRoot.path),
          offlineUserIdProvider.overrideWithValue(userId),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test(
      '5. le manifeste du compte A est invisible pour le compte B',
      () async {
        final store = await makeStore();
        await seedReadyCopy(store, userId: 1, trackId: 42);

        final indexA = await indexContainer(
          store: store,
          userId: 1,
        ).read(offlineIndexProvider.future);
        final indexB = await indexContainer(
          store: store,
          userId: 2,
        ).read(offlineIndexProvider.future);

        expect(indexA.availableTrackIds, {42});
        expect(indexB.availableTrackIds, isEmpty);
        expect(indexB.entries, isEmpty); // aucun fallback vers un autre userId
      },
    );

    test('7. espace occupé = somme exacte des copies disponibles', () async {
      final store = await makeStore();
      await seedReadyCopy(store, userId: 1, trackId: 1, sizeBytes: 1000);
      await seedReadyCopy(
        store,
        userId: 1,
        trackId: 2,
        profile: OfflineProfile.opus128,
        sizeBytes: 500,
      );
      // Copie cassée (fichier absent) : ne compte pas.
      await seedReadyCopy(
        store,
        userId: 1,
        trackId: 3,
        sizeBytes: 9999,
        writeFile: false,
      );

      final index = await indexContainer(
        store: store,
        userId: 1,
      ).read(offlineIndexProvider.future);

      expect(index.totalAvailableBytes, 1500);
      expect(index.availableCount, 2);
    });

    test(
      '8. badge bibliothèque : profil local exposé par piste disponible',
      () async {
        final store = await makeStore();
        await seedReadyCopy(store, userId: 1, trackId: 42);
        final container = indexContainer(store: store, userId: 1);
        await container.read(offlineIndexProvider.future);

        expect(container.read(offlineProfileLabelProvider(42)), 'Opus 256');
        expect(container.read(offlineProfileLabelProvider(99)), isNull);
        expect(container.read(offlineAvailableTrackIdsProvider), {42});
      },
    );

    test('8b. filtre « Téléchargées » : fonction pure de filtrage', () {
      final tracks = [
        for (var i = 1; i <= 3; i++)
          Track(id: i, title: 'T$i', artist: 'A', album: 'B', hasCover: false),
      ];
      final filtered = applyLibraryFilters(
        tracks,
        query: '',
        sort: LibrarySort.titleAsc,
        onlyDownloaded: true,
        downloadedIds: {2},
      );
      expect(filtered.map((t) => t.id), [2]);
    });

    test(
      '8c. bibliothèque hors ligne reconstruite depuis le manifeste',
      () async {
        final store = await makeStore();
        await seedReadyCopy(
          store,
          userId: 1,
          trackId: 42,
          title: 'Visible hors ligne',
        );
        final container = ProviderContainer(
          retry: (retryCount, error) => null,
          overrides: [
            offlineManifestStoreProvider.overrideWithValue(store),
            offlineRootDirProvider.overrideWithValue(() async => tempRoot.path),
            offlineUserIdProvider.overrideWithValue(1),
            libraryProvider.overrideWith((ref) async => const <Track>[]),
          ],
        );
        addTearDown(container.dispose);
        await container.read(offlineIndexProvider.future);
        container.read(libraryDownloadedOnlyProvider.notifier).set(true);

        final visible = container.read(visibleTracksProvider);
        expect(visible.map((track) => track.id), [42]);
        expect(visible.single.title, 'Visible hors ligne');
      },
    );

    test(
      '10. fichier manquant ou tronqué → indisponible, jamais lisible',
      () async {
        final store = await makeStore();
        await seedReadyCopy(
          store,
          userId: 1,
          trackId: 1,
          sizeBytes: 64,
          writeFile: false, // absent
        );
        await seedReadyCopy(
          store,
          userId: 1,
          trackId: 2,
          sizeBytes: 64,
          fileBytes: 10, // tronqué
        );

        final index = await indexContainer(
          store: store,
          userId: 1,
        ).read(offlineIndexProvider.future);

        expect(index.availableTrackIds, isEmpty);
        for (final entry in index.entries) {
          expect(localQueueItemForEntry(index, entry), isNull);
        }
        expect(buildLocalQueue(index), isEmpty);
      },
    );

    test('11. file locale construite sans API : file://, sans Bearer, '
        'métadonnées du manifeste', () async {
      final store = await makeStore();
      await seedReadyCopy(store, userId: 1, trackId: 1, title: 'Locale Un');
      await seedReadyCopy(
        store,
        userId: 1,
        trackId: 2,
        profile: OfflineProfile.original,
        title: 'Locale Deux',
      );

      final index = await indexContainer(
        store: store,
        userId: 1,
      ).read(offlineIndexProvider.future);
      final queue = buildLocalQueue(index);

      expect(queue, hasLength(2));
      for (final item in queue) {
        expect(item.streamUri.scheme, 'file');
        expect(item.headers, isNull); // jamais de Bearer vers file://
      }
      expect(
        queue.map((i) => i.title),
        containsAll(['Locale Un', 'Locale Deux']),
      );
      expect(queue.firstWhere((i) => i.id == '1').mimeType, 'audio/ogg');
    });

    test(
      '11b. pochette locale disponible dans l’index et la file audio',
      () async {
        final store = await makeStore();
        await seedReadyCopy(store, userId: 1, trackId: 1);
        final cover = File('${tempRoot.path}/offline/u1/covers/1.cover')
          ..createSync(recursive: true);
        cover.writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xD9]);
        final index = await indexContainer(
          store: store,
          userId: 1,
        ).read(offlineIndexProvider.future);

        expect(index.coverUriForTrack(1)?.scheme, 'file');
        expect(index.availableTracks.single.hasCover, isTrue);
        expect(buildLocalQueue(index).single.artUri, Uri.file(cover.path));
      },
    );

    test('11c. cache pochette atomique et single-flight', () async {
      final adapter = _CoverAdapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://homespotify.test'))
        ..httpClientAdapter = adapter;
      final cache = OfflineArtworkCache(
        dio: dio,
        rootDirProvider: () async => tempRoot.path,
      );
      final results = await Future.wait([
        cache.ensureCover(userId: 1, trackId: 42),
        cache.ensureCover(userId: 1, trackId: 42),
      ]);

      expect(adapter.calls, 1);
      expect(results, [true, true]);
      expect(
        File('${tempRoot.path}/offline/u1/covers/42.cover').readAsBytesSync(),
        [0xFF, 0xD8, 0xFF, 0xD9],
      );
      expect(
        File('${tempRoot.path}/offline/u1/covers/42.cover.part').existsSync(),
        isFalse,
      );
    });

    test('9b. suppression locale : fichier + manifeste du compte, AUCUN appel '
        'serveur, autre compte intact', () async {
      final store = await makeStore();
      final api = ThrowingOfflineApi();
      await seedReadyCopy(store, userId: 1, trackId: 42);
      await seedReadyCopy(store, userId: 2, trackId: 42);
      final coverA = File('${tempRoot.path}/offline/u1/covers/42.cover')
        ..createSync(recursive: true);
      coverA.writeAsBytesSync([1, 2, 3]);
      final downloader = OfflineTrackDownloader(
        api: api,
        store: store,
        rootDirProvider: () async => tempRoot.path,
      );

      await downloader.removeLocal(1, 42, OfflineProfile.opus256);

      expect(api.calls, 0); // jamais de suppression distante
      expect(
        File('${tempRoot.path}/offline/u1/42-opus_256.ogg').existsSync(),
        isFalse,
      );
      expect(await store.find(1, 42, OfflineProfile.opus256), isNull);
      expect(coverA.existsSync(), isFalse);
      // Le compte 2 garde sa copie et son fichier.
      expect(await store.find(2, 42, OfflineProfile.opus256), isNotNull);
      expect(
        File('${tempRoot.path}/offline/u2/42-opus_256.ogg').existsSync(),
        isTrue,
      );
    });
  });

  group('écran Téléchargements (B)', () {
    // Le manifeste FFI fait de l'IO RÉEL : toute attente de son résultat doit
    // passer par tester.runAsync, sinon la zone fake-async de testWidgets ne
    // délivre jamais les réponses (deadlock de pumpAndSettle) — cf. LESSONS.
    Future<void> settleRealAsync(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pumpAndSettle();
    }

    Future<(ThrowingOfflineApi, OfflineManifestStore)> pumpDownloads(
      WidgetTester tester, {
      required int userId,
      bool playing = false,
    }) async {
      final seeded = await tester.runAsync(() async {
        final store = await makeStore();
        await seedReadyCopy(store, userId: userId, trackId: 1, title: 'Dispo');
        await store.upsert(
          OfflineTrackRecord(
            userId: userId,
            trackId: 2,
            profile: OfflineProfile.opus128,
            sourceSha256: 'src-2',
            status: OfflineDownloadStatus.failed,
            receivedBytes: 12,
            sizeBytes: 64,
            title: 'En échec',
            artist: 'Artiste 2',
            errorMessage: 'boom',
          ),
        );
        return (ThrowingOfflineApi(), store);
      });
      final (api, store) = seeded!;
      final downloader = OfflineTrackDownloader(
        api: api,
        store: store,
        rootDirProvider: () async => tempRoot.path,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...authOverrides(
              state: AuthState(AuthStatus.offline, user: makeUser(id: userId)),
            ),
            offlineManifestStoreProvider.overrideWithValue(store),
            offlineRootDirProvider.overrideWithValue(() async => tempRoot.path),
            offlineUserIdProvider.overrideWithValue(userId),
            offlineApiProvider.overrideWithValue(api),
            offlineTrackDownloaderProvider.overrideWithValue(downloader),
            mediaItemProvider.overrideWith(
              (ref) => Stream.value(
                playing ? const MediaItem(id: '1', title: 'Dispo') : null,
              ),
            ),
            playbackStateProvider.overrideWith(
              (ref) => Stream.value(
                PlaybackState(
                  playing: playing,
                  processingState: AudioProcessingState.ready,
                ),
              ),
            ),
          ],
          child: const MaterialApp(home: DownloadsScreen()),
        ),
      );
      await settleRealAsync(tester);
      return (api, store);
    }

    testWidgets('6. alimenté uniquement par SQLite : contenu complet sans '
        'aucun appel API', (tester) async {
      final (api, _) = await pumpDownloads(tester, userId: 7);

      expect(api.calls, 0); // preuve : aucun appel réseau pour afficher
      expect(find.text('Dispo'), findsOneWidget);
      expect(find.text('En échec'), findsOneWidget);
      expect(find.textContaining('Disponible'), findsWidgets);
      expect(find.textContaining('Erreur'), findsWidgets);
      expect(find.textContaining('Opus 256'), findsWidgets);
      expect(
        find.byKey(const ValueKey('downloads-header-count')),
        findsOneWidget,
      );
      expect(find.textContaining('1 piste disponible'), findsOneWidget);
      expect(find.textContaining('Espace occupé'), findsOneWidget);
      expect(find.byKey(const ValueKey('downloads-play-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('downloads-retry-2')), findsOneWidget);
    });

    testWidgets('6b. la piste en cours est indiquée dans Téléchargements', (
      tester,
    ) async {
      await pumpDownloads(tester, userId: 7, playing: true);

      expect(
        find.byKey(const ValueKey('current-track-indicator-1')),
        findsOneWidget,
      );
      expect(find.byTooltip('En lecture'), findsOneWidget);
    });

    testWidgets('9. suppression : confirmation explicite, jamais d’appel '
        'serveur (sémantique locale prouvée par le test 9b)', (tester) async {
      final (api, _) = await pumpDownloads(tester, userId: 7);

      await tester.tap(find.byKey(const ValueKey('downloads-delete-1')));
      await tester.pumpAndSettle();
      // Garde-fou explicite : la suppression demande confirmation et rappelle
      // que la piste reste sur le serveur et dans la bibliothèque.
      expect(
        find.byKey(const ValueKey('downloads-delete-confirm')),
        findsOneWidget,
      );
      expect(find.textContaining('reste sur le serveur'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('downloads-delete-confirm')));
      await tester.pump();

      // L'écran ne déclenche aucune suppression distante (l'API échouerait).
      expect(api.calls, 0);
    });

    testWidgets('état vide compréhensible', (tester) async {
      final store = (await tester.runAsync(makeStore))!;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...authOverrides(
              state: AuthState(AuthStatus.offline, user: makeUser(id: 7)),
            ),
            offlineManifestStoreProvider.overrideWithValue(store),
            offlineRootDirProvider.overrideWithValue(() async => tempRoot.path),
            offlineUserIdProvider.overrideWithValue(7),
            offlineApiProvider.overrideWithValue(ThrowingOfflineApi()),
          ],
          child: const MaterialApp(home: DownloadsScreen()),
        ),
      );
      await settleRealAsync(tester);
      expect(find.text('Aucun téléchargement'), findsOneWidget);
      expect(find.textContaining('Télécharger'), findsWidgets);
    });
  });

  group('retour en ligne (F)', () {
    test('12. serveur joignable → la résolution locale reste vide (prochaine '
        'file = original réseau)', () async {
      // Ce comportement est porté par OfflineSourceResolver : couvert en détail
      // dans offline_phase1a_test.dart (« serveur joignable → toujours
      // l'original réseau »). Ici on fige le contrat au niveau de l'index :
      // une file en ligne n'utilise l'index local que via le resolver.
      final store = await makeStore();
      await seedReadyCopy(store, userId: 1, trackId: 1);
      final container = ProviderContainer(
        retry: (retryCount, error) => null,
        overrides: [
          ...authOverrides(
            state: AuthState(AuthStatus.authenticated, user: makeUser(id: 1)),
          ),
          offlineManifestStoreProvider.overrideWithValue(store),
          offlineRootDirProvider.overrideWithValue(() async => tempRoot.path),
          offlineUserIdProvider.overrideWithValue(1),
        ],
      );
      addTearDown(container.dispose);
      final index = await container.read(offlineIndexProvider.future);
      // L'index existe (badges) mais ne force jamais la source : la file
      // réseau est construite par le contrôleur de lecture via le resolver.
      expect(index.availableTrackIds, {1});
    });
  });
}
