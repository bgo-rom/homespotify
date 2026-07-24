import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homespotify_mobile/src/features/auth/application/auth_controller.dart';
import 'package:homespotify_mobile/src/features/library/domain/track.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_playback_controller.dart';
import 'package:homespotify_mobile/src/features/offline/application/offline_profile_preference.dart';
import 'package:homespotify_mobile/src/features/offline/application/offline_source_resolver.dart';
import 'package:homespotify_mobile/src/features/offline/application/offline_track_downloader.dart';
import 'package:homespotify_mobile/src/features/offline/data/offline_api.dart';
import 'package:homespotify_mobile/src/features/offline/data/offline_manifest_store.dart';
import 'package:homespotify_mobile/src/features/offline/domain/offline_models.dart';
import 'package:homespotify_mobile/src/features/offline/presentation/offline_download_sheet.dart';
import 'package:homespotify_mobile/src/features/library/data/library_api.dart';
import 'package:just_audio/just_audio.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_auth.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

Track makeTrack({
  int id = 1,
  String? etag = 'source-hash',
  int sizeBytes = 42000000,
}) => Track(
  id: id,
  title: 'Billie Jean',
  artist: 'Michael Jackson',
  album: 'Thriller',
  hasCover: false,
  durationSeconds: 120,
  sizeBytes: sizeBytes,
  etag: etag,
  mimeType: 'audio/flac',
  extension: '.flac',
);

class FakeOfflineApi implements OfflineApi {
  FakeOfflineApi({List<int>? bytes, this.pendingPolls = 0})
    : bytes = bytes ?? List<int>.generate(2048, (i) => i % 251);

  final List<int> bytes;
  int pendingPolls; // nombre de sondages avant READY
  bool failEncoding = false;
  bool file404 = false;
  bool cancelAfterFirstChunk = false;
  String? shaOverride;

  int requestCalls = 0;
  int statusCalls = 0;
  final List<int> fromBytes = [];

  String get sha => shaOverride ?? sha256.convert(bytes).toString();

  OfflineVariantState _state(OfflineProfile profile, String status) =>
      OfflineVariantState(
        profile: profile,
        status: status,
        sourceSha256: 'source-hash',
        sizeBytes: status == 'READY' ? bytes.length : bytes.length,
        sizeKind: status == 'READY' ? 'exact' : 'estimated',
        sha256: status == 'READY' ? sha : null,
        measuredBitrateKbps: status == 'READY' ? 131 : null,
      );

  @override
  Future<List<OfflineOption>> fetchOptions(int trackId) async => [
    OfflineOption(
      profile: OfflineProfile.opus128,
      lossy: true,
      status: 'NOT_REQUESTED',
      recommended: false,
      sizeBytes: 1920000,
      sizeKind: 'estimated',
      sourceSha256: 'source-hash',
    ),
    OfflineOption(
      profile: OfflineProfile.opus256,
      lossy: true,
      status: 'NOT_REQUESTED',
      recommended: true,
      sizeBytes: 3840000,
      sizeKind: 'estimated',
      sourceSha256: 'source-hash',
    ),
    OfflineOption(
      profile: OfflineProfile.original,
      lossy: false,
      status: 'READY',
      recommended: false,
      qualityStatus: 'lossless_verifie',
      codec: 'flac',
      sizeBytes: 42000000,
      sizeKind: 'exact',
      sha256: 'source-hash',
      sourceSha256: 'source-hash',
    ),
  ];

  @override
  Future<OfflineVariantState> requestVariant(
    int trackId,
    OfflineProfile profile, {
    CancelToken? cancelToken,
  }) async {
    final cancelError = cancelToken?.cancelError;
    if (cancelError != null) throw cancelError;
    requestCalls += 1;
    if (failEncoding) return _state(profile, 'FAILED');
    return _state(profile, pendingPolls > 0 ? 'PENDING' : 'READY');
  }

  @override
  Future<OfflineVariantState> variantStatus(
    int trackId,
    OfflineProfile profile, {
    CancelToken? cancelToken,
  }) async {
    final cancelError = cancelToken?.cancelError;
    if (cancelError != null) throw cancelError;
    statusCalls += 1;
    if (pendingPolls > 0) pendingPolls -= 1;
    return _state(profile, pendingPolls > 0 ? 'ENCODING' : 'READY');
  }

  @override
  Uri downloadUri(int trackId, OfflineProfile profile) =>
      Uri.parse('http://test/$trackId/${profile.wire}');

  @override
  Future<Response<ResponseBody>> openDownloadStream(
    int trackId,
    OfflineProfile profile, {
    int fromByte = 0,
    CancelToken? cancelToken,
  }) async {
    fromBytes.add(fromByte);
    final options = RequestOptions(path: downloadUri(trackId, profile).path);
    if (file404) {
      return Response<ResponseBody>(requestOptions: options, statusCode: 404);
    }
    if (fromByte >= bytes.length) {
      return Response<ResponseBody>(requestOptions: options, statusCode: 416);
    }
    final remaining = bytes.sublist(fromByte);
    Stream<Uint8List> chunks() async* {
      const chunkSize = 512;
      var emitted = 0;
      for (var i = 0; i < remaining.length; i += chunkSize) {
        final end = (i + chunkSize).clamp(0, remaining.length);
        yield Uint8List.fromList(remaining.sublist(i, end));
        emitted += 1;
        await Future<void>.delayed(Duration.zero);
        if (cancelAfterFirstChunk &&
            emitted >= 1 &&
            (cancelToken?.isCancelled ?? false)) {
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.cancel,
          );
        }
      }
    }

    return Response<ResponseBody>(
      requestOptions: options,
      statusCode: fromByte > 0 ? 206 : 200,
      data: ResponseBody(chunks(), fromByte > 0 ? 206 : 200),
    );
  }
}

class InMemoryProfilePreference implements OfflineProfilePreference {
  OfflineProfile stored = OfflineProfile.opus256;
  final List<OfflineProfile> saves = [];

  @override
  Future<OfflineProfile> load() async => stored;

  @override
  Future<void> save(OfflineProfile profile) async {
    stored = profile;
    saves.add(profile);
  }
}

/// Downloader stub pour les tests de widget : aucun fichier réel.
class StubDownloader extends OfflineTrackDownloader {
  StubDownloader({required super.api, required super.store})
    : super(rootDirProvider: () async => '/unused');

  int calls = 0;

  @override
  Future<OfflineTrackRecord> download({
    required int userId,
    required Track track,
    required OfflineProfile profile,
    CancelToken? cancelToken,
    void Function(OfflineDownloadProgress progress)? onProgress,
  }) async {
    calls += 1;
    onProgress?.call(
      const OfflineDownloadProgress(
        status: OfflineDownloadStatus.ready,
        receivedBytes: 10,
        totalBytes: 10,
      ),
    );
    return OfflineTrackRecord(
      userId: userId,
      trackId: track.id,
      profile: profile,
      sourceSha256: 'source-hash',
      status: OfflineDownloadStatus.ready,
      receivedBytes: 10,
    );
  }
}

// ---------------------------------------------------------------------------
// Aides
// ---------------------------------------------------------------------------

late Directory tempRoot;
int storeCounter = 0;

Future<SqliteOfflineManifestStore> makeStore() async {
  storeCounter += 1;
  return SqliteOfflineManifestStore(
    factory: databaseFactoryFfi,
    databasePath: '${tempRoot.path}/manifest-$storeCounter.db',
  );
}

OfflineTrackDownloader makeDownloader(
  FakeOfflineApi api,
  OfflineManifestStore store,
) => OfflineTrackDownloader(
  api: api,
  store: store,
  rootDirProvider: () async => tempRoot.path,
  pollInterval: Duration.zero,
  maxPollAttempts: 5,
);

void main() {
  sqfliteFfiInit();

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('homespotify-offline-test');
  });

  tearDown(() {
    try {
      tempRoot.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows : un handle sqlite peut se fermer légèrement après le test.
    }
  });

  group('OfflineTrackDownloader — verticale une piste', () {
    test(
      '202 → sondage borné → .part → SHA-256 valide → publication atomique',
      () async {
        final api = FakeOfflineApi(pendingPolls: 2);
        final store = await makeStore();
        final progresses = <OfflineDownloadStatus>[];

        final record = await makeDownloader(api, store).download(
          userId: 7,
          track: makeTrack(),
          profile: OfflineProfile.opus256,
          onProgress: (p) => progresses.add(p.status),
        );

        expect(record.status, OfflineDownloadStatus.ready);
        expect(record.relativePath, '1-opus_256.ogg');
        final file = File('${tempRoot.path}/offline/u7/1-opus_256.ogg');
        expect(file.existsSync(), isTrue);
        expect(sha256.convert(file.readAsBytesSync()).toString(), api.sha);
        expect(
          File('${file.path}.part').existsSync(),
          isFalse, // jamais de .part publié
        );
        expect(progresses, contains(OfflineDownloadStatus.waitingServer));
        expect(progresses, contains(OfflineDownloadStatus.verifying));
        expect(progresses.last, OfflineDownloadStatus.ready);
        // Manifeste : ready, taille exacte, partition compte.
        final saved = await store.find(7, 1, OfflineProfile.opus256);
        expect(saved?.status, OfflineDownloadStatus.ready);
        expect(saved?.sizeBytes, api.bytes.length);
      },
    );

    test('reprise : un .part existant repart de son offset (Range)', () async {
      final api = FakeOfflineApi();
      final store = await makeStore();
      final downloader = makeDownloader(api, store);
      // Première moitié déjà téléchargée puis interrompue.
      final dir = Directory('${tempRoot.path}/offline/u7')
        ..createSync(recursive: true);
      File(
        '${dir.path}/1-opus_128.ogg.part',
      ).writeAsBytesSync(api.bytes.sublist(0, 1000));
      await store.upsert(
        OfflineTrackRecord(
          userId: 7,
          trackId: 1,
          profile: OfflineProfile.opus128,
          sourceSha256: 'source-hash',
          expectedSha256: api.sha,
          status: OfflineDownloadStatus.cancelled,
          receivedBytes: 1000,
        ),
      );

      final record = await downloader.download(
        userId: 7,
        track: makeTrack(),
        profile: OfflineProfile.opus128,
      );

      expect(api.fromBytes, [1000]); // reprise, pas de retéléchargement complet
      expect(record.status, OfflineDownloadStatus.ready);
      final file = File('${dir.path}/1-opus_128.ogg');
      expect(sha256.convert(file.readAsBytesSync()).toString(), api.sha);
    });

    test(
      'hash invalide → rejet, aucun fichier publié, .part supprimé',
      () async {
        final api = FakeOfflineApi()..shaOverride = 'a' * 64;
        final store = await makeStore();

        await expectLater(
          makeDownloader(api, store).download(
            userId: 7,
            track: makeTrack(),
            profile: OfflineProfile.opus128,
          ),
          throwsA(isA<OfflineDownloadException>()),
        );

        final dir = Directory('${tempRoot.path}/offline/u7');
        expect(File('${dir.path}/1-opus_128.ogg').existsSync(), isFalse);
        expect(File('${dir.path}/1-opus_128.ogg.part').existsSync(), isFalse);
        final saved = await store.find(7, 1, OfflineProfile.opus128);
        expect(saved?.status, OfflineDownloadStatus.failed);
      },
    );

    test(
      'annulation : .part conservé, état cancelled, reprise possible',
      () async {
        final api = FakeOfflineApi()..cancelAfterFirstChunk = true;
        final store = await makeStore();
        final downloader = makeDownloader(api, store);
        final cancelToken = CancelToken();

        await expectLater(
          downloader.download(
            userId: 7,
            track: makeTrack(),
            profile: OfflineProfile.opus128,
            cancelToken: cancelToken,
            onProgress: (p) {
              if (p.status == OfflineDownloadStatus.downloading) {
                cancelToken.cancel();
              }
            },
          ),
          throwsA(isA<DioException>()),
        );

        final saved = await store.find(7, 1, OfflineProfile.opus128);
        expect(saved?.status, OfflineDownloadStatus.cancelled);
        final part = File('${tempRoot.path}/offline/u7/1-opus_128.ogg.part');
        expect(part.existsSync(), isTrue); // reprise possible

        // Retry : reprend et aboutit.
        api.cancelAfterFirstChunk = false;
        final record = await downloader.download(
          userId: 7,
          track: makeTrack(),
          profile: OfflineProfile.opus128,
        );
        expect(record.status, OfflineDownloadStatus.ready);
        expect(api.fromBytes.last, greaterThan(0)); // vraie reprise Range
      },
    );

    test('annulation pendant la préparation serveur avant transfert', () async {
      final api = FakeOfflineApi(pendingPolls: 10);
      final store = await makeStore();
      final cancelToken = CancelToken();
      final downloader = OfflineTrackDownloader(
        api: api,
        store: store,
        rootDirProvider: () async => tempRoot.path,
        pollInterval: const Duration(seconds: 30),
        maxPollAttempts: 20,
      );

      await expectLater(
        downloader.download(
          userId: 7,
          track: makeTrack(),
          profile: OfflineProfile.opus256,
          cancelToken: cancelToken,
          onProgress: (progress) {
            if (progress.status == OfflineDownloadStatus.waitingServer &&
                !cancelToken.isCancelled) {
              cancelToken.cancel('test');
            }
          },
        ),
        throwsA(isA<DioException>()),
      );
      expect(api.fromBytes, isEmpty);
    });

    test('stockage local indisponible : aucun faux READY', () async {
      final api = FakeOfflineApi();
      final store = await makeStore();
      final invalidRoot = File('${tempRoot.path}/not-a-directory')
        ..writeAsStringSync('x');
      final downloader = OfflineTrackDownloader(
        api: api,
        store: store,
        rootDirProvider: () async => invalidRoot.path,
      );

      await expectLater(
        downloader.download(
          userId: 7,
          track: makeTrack(),
          profile: OfflineProfile.opus128,
        ),
        throwsA(
          isA<OfflineDownloadException>().having(
            (error) => error.message,
            'message',
            contains('stockage hors ligne'),
          ),
        ),
      );
      expect(await store.readyForTrack(7, 1), isEmpty);
    });

    test(
      'échec d’encodage serveur → erreur explicite, rien sur le disque',
      () async {
        final api = FakeOfflineApi()..failEncoding = true;
        final store = await makeStore();
        await expectLater(
          makeDownloader(api, store).download(
            userId: 7,
            track: makeTrack(),
            profile: OfflineProfile.opus256,
          ),
          throwsA(isA<OfflineDownloadException>()),
        );
        expect(
          Directory('${tempRoot.path}/offline/u7').existsSync()
              ? Directory('${tempRoot.path}/offline/u7').listSync()
              : const <FileSystemEntity>[],
          isEmpty,
        );
      },
    );

    test(
      'variante disparue côté serveur (404) → échec net, sans boucle',
      () async {
        final api = FakeOfflineApi()..file404 = true;
        final store = await makeStore();
        await expectLater(
          makeDownloader(api, store).download(
            userId: 7,
            track: makeTrack(),
            profile: OfflineProfile.opus128,
          ),
          throwsA(isA<OfflineDownloadException>()),
        );
        expect(api.fromBytes, hasLength(1)); // une seule tentative
      },
    );

    test(
      "l'original se télécharge par la route canonique avec son hash",
      () async {
        final api = FakeOfflineApi();
        final store = await makeStore();
        final originalBytes = api.bytes;
        final track = makeTrack(
          etag: sha256.convert(originalBytes).toString(),
          sizeBytes: originalBytes.length,
        );
        final record = await makeDownloader(
          api,
          store,
        ).download(userId: 7, track: track, profile: OfflineProfile.original);
        expect(record.status, OfflineDownloadStatus.ready);
        expect(record.relativePath, '1-original.flac');
        expect(api.requestCalls, 0); // jamais de variante pour l'original
      },
    );
  });

  group('manifeste SQLite — isolation par compte', () {
    test(
      'les copies d’Alice sont invisibles pour Bob, purge par compte',
      () async {
        final store = await makeStore();
        Future<void> seed(int userId) => store.upsert(
          OfflineTrackRecord(
            userId: userId,
            trackId: 1,
            profile: OfflineProfile.opus256,
            sourceSha256: 'source-hash',
            status: OfflineDownloadStatus.ready,
            receivedBytes: 10,
            relativePath: '1-opus_256.ogg',
            sizeBytes: 10,
          ),
        );
        await seed(1);
        await seed(2);

        expect(await store.readyForTrack(1, 1), hasLength(1));
        expect(await store.readyForTrack(2, 1), hasLength(1));
        expect(await store.find(3, 1, OfflineProfile.opus256), isNull);

        await store.delete(1, 1, OfflineProfile.opus256);
        expect(await store.readyForTrack(1, 1), isEmpty);
        expect(await store.readyForTrack(2, 1), hasLength(1)); // Bob intact
      },
    );
  });

  group('sélection de source — online/offline', () {
    Future<OfflineManifestStore> seededStore(int userId) async {
      final store = await makeStore();
      final dir = Directory('${tempRoot.path}/offline/u$userId')
        ..createSync(recursive: true);
      for (final (profile, name) in [
        (OfflineProfile.opus128, '1-opus_128.ogg'),
        (OfflineProfile.opus256, '1-opus_256.ogg'),
      ]) {
        File('${dir.path}/$name').writeAsBytesSync(List.filled(64, 1));
        await store.upsert(
          OfflineTrackRecord(
            userId: userId,
            trackId: 1,
            profile: profile,
            sourceSha256: 'source-hash',
            status: OfflineDownloadStatus.ready,
            receivedBytes: 64,
            sizeBytes: 64,
            relativePath: name,
          ),
        );
      }
      return store;
    }

    test('serveur joignable → toujours l’original réseau (map vide)', () async {
      final resolver = OfflineSourceResolver(
        store: await seededStore(7),
        rootDirProvider: () async => tempRoot.path,
        serverReachable: () async => true,
      );
      final sources = await resolver.resolveLocalSources(
        userId: 7,
        tracks: [makeTrack()],
      );
      expect(sources, isEmpty);
    });

    test(
      'serveur injoignable → meilleure copie locale vérifiée (256 > 128)',
      () async {
        final resolver = OfflineSourceResolver(
          store: await seededStore(7),
          rootDirProvider: () async => tempRoot.path,
          serverReachable: () async => false,
        );
        final sources = await resolver.resolveLocalSources(
          userId: 7,
          tracks: [makeTrack()],
        );
        expect(sources[1]?.profile, OfflineProfile.opus256);
        expect(sources[1]?.uri.scheme, 'file');
      },
    );

    test('hash source remplacé : ancienne copie locale refusée', () async {
      var probeCalled = false;
      final resolver = OfflineSourceResolver(
        store: await seededStore(7),
        rootDirProvider: () async => tempRoot.path,
        serverReachable: () async {
          probeCalled = true;
          return false;
        },
      );
      final sources = await resolver.resolveLocalSources(
        userId: 7,
        tracks: [makeTrack(etag: 'new-source-hash')],
      );
      expect(sources, isEmpty);
      expect(probeCalled, isFalse);
    });

    test('copie tronquée (taille ≠ manifeste) → jamais servie', () async {
      final store = await seededStore(7);
      // Corrompt la 256 : la 128 doit prendre le relais.
      File(
        '${tempRoot.path}/offline/u7/1-opus_256.ogg',
      ).writeAsBytesSync(List.filled(10, 1));
      final resolver = OfflineSourceResolver(
        store: store,
        rootDirProvider: () async => tempRoot.path,
        serverReachable: () async => false,
      );
      final sources = await resolver.resolveLocalSources(
        userId: 7,
        tracks: [makeTrack()],
      );
      expect(sources[1]?.profile, OfflineProfile.opus128);
    });

    test(
      'hors ligne : le cache d’un AUTRE compte n’est jamais servi',
      () async {
        final resolver = OfflineSourceResolver(
          store: await seededStore(7),
          rootDirProvider: () async => tempRoot.path,
          serverReachable: () async => false,
        );
        final sources = await resolver.resolveLocalSources(
          userId: 8, // Bob n'a rien téléchargé
          tracks: [makeTrack()],
        );
        expect(sources, isEmpty);
      },
    );

    test(
      'la source initiale est choisie À LA CONSTRUCTION de la file : '
      'un item local garde son URI fichier, un item réseau son URI stream',
      () {
        final api = LibraryApi(Dio(), 'http://test');
        final local = playerQueueItemForTrack(
          track: makeTrack(),
          api: api,
          userId: 7,
          authorizationHeaders: const {'Authorization': 'Bearer x'},
          localSource: ResolvedLocalSource(
            uri: Uri.file('/tmp/1-opus_256.ogg'),
            profile: OfflineProfile.opus256,
            mimeType: 'audio/ogg',
          ),
          preferLocalSource: true,
        );
        expect(local.streamUri.scheme, 'file');
        expect(
          (local.toAudioSource() as UriAudioSource).headers,
          isNull,
        ); // jamais de Bearer envoyé vers un fichier local
        expect(local.headers, const {
          'Authorization': 'Bearer x',
        }); // conservé uniquement pour un éventuel retour au réseau
        expect(local.mimeType, 'audio/ogg');

        final network = playerQueueItemForTrack(
          track: makeTrack(),
          api: api,
          userId: 7,
          authorizationHeaders: const {'Authorization': 'Bearer x'},
        );
        expect(network.streamUri.scheme, 'http');
        expect(network.headers, isNotNull);
      },
    );
  });

  group('feuille de téléchargement — trois choix véraces', () {
    Future<(FakeOfflineApi, InMemoryProfilePreference, StubDownloader)>
    pumpSheet(WidgetTester tester) async {
      final api = FakeOfflineApi();
      final preference = InMemoryProfilePreference();
      final store = await makeStore();
      final downloader = StubDownloader(api: api, store: store);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...authOverrides(
              state: AuthState(AuthStatus.authenticated, user: makeUser()),
            ),
            offlineApiProvider.overrideWithValue(api),
            offlineProfilePreferenceProvider.overrideWithValue(preference),
            offlineTrackDownloaderProvider.overrideWithValue(downloader),
          ],
          child: MaterialApp(
            home: Scaffold(body: OfflineDownloadSheet(track: makeTrack())),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (api, preference, downloader);
    }

    testWidgets('rend les trois choix avec tailles estimées/exactes', (
      tester,
    ) async {
      await pumpSheet(tester);
      expect(find.text('Opus 128 kb/s'), findsOneWidget);
      expect(find.text('Opus 256 kb/s'), findsOneWidget);
      expect(find.text('Original (copie exacte)'), findsOneWidget);
      // Les deux Opus sont explicitement lossy et à taille ESTIMÉE.
      expect(find.textContaining('compressé (lossy)'), findsNWidgets(2));
      expect(find.textContaining('(estimée)'), findsNWidgets(2));
      // L'original expose sa taille exacte et sa qualité mesurée, jamais
      // « lossless » sans preuve : le statut d'analyse est affiché tel quel.
      expect(find.textContaining('42.0 Mo'), findsOneWidget);
      expect(find.textContaining('qualité lossless_verifie'), findsOneWidget);
    });

    testWidgets('Opus 256 est recommandé et présélectionné', (tester) async {
      await pumpSheet(tester);
      expect(find.text('Recommandé'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('offline-choice-opus_256')),
          matching: find.byIcon(Icons.radio_button_checked_rounded),
        ),
        findsOneWidget,
      );
    });

    testWidgets('le choix reste modifiable et la préférence est mémorisée', (
      tester,
    ) async {
      final (_, preference, downloader) = await pumpSheet(tester);
      await tester.tap(find.byKey(const ValueKey('offline-choice-opus_128')));
      await tester.pump();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('offline-choice-opus_128')),
          matching: find.byIcon(Icons.radio_button_checked_rounded),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('offline-download-start')));
      await tester.pumpAndSettle();
      expect(downloader.calls, 1);
      expect(preference.saves, [OfflineProfile.opus128]);
      expect(
        find.byKey(const ValueKey('offline-download-done')),
        findsOneWidget,
      );
    });
  });
}
