import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homespotify_mobile/src/features/catalog_search/application/catalog_search_controller.dart';
import 'package:homespotify_mobile/src/features/catalog_search/data/catalog_search_api.dart';
import 'package:homespotify_mobile/src/features/catalog_search/domain/catalog_models.dart';
import 'package:homespotify_mobile/src/features/catalog_search/presentation/catalog_preview_controller.dart';
import 'package:homespotify_mobile/src/features/catalog_search/presentation/catalog_search_screen.dart';
import 'package:homespotify_mobile/src/features/library/data/library_api.dart';
import 'package:homespotify_mobile/src/features/library/domain/track.dart';
import 'package:homespotify_mobile/src/features/remote_download/data/remote_download_api.dart';
import 'package:homespotify_mobile/src/features/remote_download/domain/remote_download_models.dart';

import 'support/fake_audio_player.dart';
import 'support/fake_remote_download.dart';

class FakeCatalogRepository implements CatalogSearchRepository {
  final Map<String, CatalogSearchPage> responses = {};
  CatalogSearchException? failWith;
  int searchCalls = 0;

  @override
  Future<CatalogSearchPage> search({
    required String query,
    String? cursor,
    int limit = 20,
  }) async {
    searchCalls += 1;
    final error = failWith;
    if (error != null) throw error;
    return responses[query] ?? const CatalogSearchPage(items: []);
  }

  @override
  Future<List<ProviderStatus>> fetchProviders() async => const [];
}

CatalogResult trackResult(
  String key, {
  String title = 'Chanson',
  String artist = 'Artiste',
  String? album = 'Album',
  int? durationMs = 201000,
  String? isrc,
  List<PlatformLink> links = const [],
  CatalogPreview? preview,
}) {
  return CatalogResult(
    canonicalKey: key,
    title: title,
    artistNames: [artist],
    album: album,
    durationMs: durationMs,
    isrc: isrc,
    links: links,
    preview: preview,
  );
}

Widget makeApp(
  FakeCatalogRepository repository, {
  List<Track> library = const [],
  FakeRemoteDownloadRepository? downloads,
}) {
  return ProviderScope(
    overrides: [
      catalogSearchApiProvider.overrideWithValue(repository),
      libraryProvider.overrideWith((ref) async => library),
      catalogPreviewPlayerFactoryProvider.overrideWithValue(
        FakeAudioPlayer.new,
      ),
      remoteDownloadApiProvider.overrideWithValue(
        downloads ?? FakeRemoteDownloadRepository(),
      ),
    ],
    child: const MaterialApp(home: CatalogSearchScreen()),
  );
}

Future<void> submitSearch(WidgetTester tester, String query) async {
  await tester.enterText(
    find.byKey(const ValueKey('catalog-search-field')),
    query,
  );
  await tester.pump(kCatalogSearchDebounce + const Duration(milliseconds: 80));
  await tester.pumpAndSettle();
}

void main() {
  group('dedupePositiveLinks', () {
    test('garde un seul lien par plateforme, CONFIRMED prioritaire', () {
      final result = dedupePositiveLinks(const [
        PlatformLink(
          platform: 'deezer',
          status: PlatformAvailability.linkFound,
          url: 'https://a',
        ),
        PlatformLink(
          platform: 'deezer',
          status: PlatformAvailability.confirmed,
          url: 'https://b',
        ),
        PlatformLink(
          platform: 'spotify',
          status: PlatformAvailability.confirmed,
        ),
      ]);

      expect(result, hasLength(2));
      final deezer = result.firstWhere((l) => l.platform == 'deezer');
      expect(deezer.status, PlatformAvailability.confirmed);
      expect(deezer.url, 'https://b');
    });

    test('écarte les statuts non positifs', () {
      final result = dedupePositiveLinks(const [
        PlatformLink(platform: 'tidal', status: PlatformAvailability.unknown),
        PlatformLink(
          platform: 'tidal',
          status: PlatformAvailability.providerError,
        ),
      ]);
      expect(result, isEmpty);
    });

    test('aucune clé dupliquée possible en sortie', () {
      final result = dedupePositiveLinks(const [
        PlatformLink(
          platform: 'deezer',
          status: PlatformAvailability.confirmed,
        ),
        PlatformLink(
          platform: 'deezer',
          status: PlatformAvailability.confirmed,
        ),
        PlatformLink(
          platform: 'deezer',
          status: PlatformAvailability.linkFound,
        ),
      ]);
      final platforms = result.map((l) => l.platform).toList();
      expect(platforms.toSet(), hasLength(platforms.length));
    });
  });

  testWidgets('un seul champ, aucun onglet de type', (tester) async {
    await tester.pumpWidget(makeApp(FakeCatalogRepository()));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget);
    expect(
      find.text('Rechercher un titre, un artiste, un album ou un ISRC…'),
      findsOneWidget,
    );
    // Aucun onglet Titres / Artistes / Albums / Playlists.
    expect(find.byType(ChoiceChip), findsNothing);
    for (final label in ['Titres', 'Artistes', 'Albums', 'Playlists']) {
      expect(find.text(label), findsNothing);
    }
  });

  testWidgets('état initial : message d’accueil, aucune requête', (
    tester,
  ) async {
    final repository = FakeCatalogRepository();
    await tester.pumpWidget(makeApp(repository));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('catalog-search-initial')),
      findsOneWidget,
    );
    expect(repository.searchCalls, 0);
  });

  testWidgets('recherche trop courte : indication dédiée', (tester) async {
    await tester.pumpWidget(makeApp(FakeCatalogRepository()));
    await tester.enterText(
      find.byKey(const ValueKey('catalog-search-field')),
      'a',
    );
    await tester.pumpAndSettle();
    expect(find.text('Tape au moins 2 caractères.'), findsOneWidget);
  });

  testWidgets('la recherche ne retourne que des pistes, avec leur identité', (
    tester,
  ) async {
    final repository = FakeCatalogRepository();
    repository.responses['muse'] = CatalogSearchPage(
      items: [
        trackResult(
          'k1',
          title: 'Uprising',
          artist: 'Muse',
          album: 'The Resistance',
          links: const [
            PlatformLink(
              platform: 'spotify',
              status: PlatformAvailability.confirmed,
              url: 'https://open.spotify.com/track/x',
            ),
            PlatformLink(
              platform: 'bandcamp',
              status: PlatformAvailability.unknown,
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(makeApp(repository));
    await submitSearch(tester, 'muse');

    // Pochette, titre, artiste, album et durée sur la carte.
    expect(find.text('Uprising'), findsOneWidget);
    expect(find.text('Muse · The Resistance · 3:21'), findsOneWidget);
    // Catalogues ayant identifié le morceau : uniquement les positifs.
    expect(
      find.byKey(const ValueKey('platform-badge-spotify')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('platform-badge-bandcamp')), findsNothing);
    expect(find.byKey(const ValueKey('install-button-k1')), findsOneWidget);
  });

  testWidgets('état vide après recherche sans résultat', (tester) async {
    await tester.pumpWidget(makeApp(FakeCatalogRepository()));
    await submitSearch(tester, 'zzzz introuvable');
    expect(find.byKey(const ValueKey('catalog-search-empty')), findsOneWidget);
  });

  testWidgets('erreur globale : message + bouton Réessayer', (tester) async {
    final repository = FakeCatalogRepository();
    repository.failWith = const CatalogSearchException('Serveur injoignable');
    await tester.pumpWidget(makeApp(repository));
    await submitSearch(tester, 'muse');
    expect(find.byKey(const ValueKey('catalog-search-error')), findsOneWidget);
    expect(find.text('Serveur injoignable'), findsOneWidget);
    repository.failWith = null;
    repository.responses['muse'] = CatalogSearchPage(
      items: [trackResult('k1', title: 'Uprising')],
    );
    await tester.tap(find.byKey(const ValueKey('catalog-search-retry')));
    await tester.pumpAndSettle();
    expect(find.text('Uprising'), findsOneWidget);
  });

  testWidgets('badge « Dans ma bibliothèque » quand la piste est possédée', (
    tester,
  ) async {
    final repository = FakeCatalogRepository();
    repository.responses['uprising'] = CatalogSearchPage(
      items: [trackResult('k1', title: 'Uprising', artist: 'Muse')],
    );
    await tester.pumpWidget(
      makeApp(
        repository,
        library: const [
          Track(
            id: 1,
            title: 'Uprising',
            artist: 'Muse',
            album: 'The Resistance',
            hasCover: false,
          ),
        ],
      ),
    );
    await submitSearch(tester, 'uprising');
    expect(find.byKey(const ValueKey('badge-owned')), findsOneWidget);
  });

  group('preview', () {
    testWidgets('lecture puis pause sur le même bouton', (tester) async {
      final repository = FakeCatalogRepository();
      repository.responses['muse'] = CatalogSearchPage(
        items: [
          trackResult(
            'k1',
            preview: const CatalogPreview(
              provider: 'itunes',
              url: 'https://cdn.example/p.m4a',
            ),
          ),
        ],
      );
      await tester.pumpWidget(makeApp(repository));
      await submitSearch(tester, 'muse');

      await tester.tap(find.byKey(const ValueKey('preview-button-k1')));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.pause_circle_rounded), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('preview-button-k1')));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.pause_circle_rounded), findsNothing);
    });

    testWidgets('absence de preview clairement signalée', (tester) async {
      final repository = FakeCatalogRepository();
      repository.responses['muse'] = CatalogSearchPage(
        items: [trackResult('k1')],
      );
      await tester.pumpWidget(makeApp(repository));
      await submitSearch(tester, 'muse');

      expect(find.byKey(const ValueKey('preview-button-k1')), findsNothing);
      expect(find.byKey(const ValueKey('preview-unavailable')), findsOneWidget);
    });

    testWidgets('un aperçu ne crée aucun job de téléchargement', (
      tester,
    ) async {
      final repository = FakeCatalogRepository();
      repository.responses['muse'] = CatalogSearchPage(
        items: [
          trackResult(
            'k1',
            preview: const CatalogPreview(
              provider: 'itunes',
              url: 'https://cdn.example/p.m4a',
            ),
          ),
        ],
      );
      final downloads = FakeRemoteDownloadRepository();
      await tester.pumpWidget(makeApp(repository, downloads: downloads));
      await submitSearch(tester, 'muse');

      await tester.tap(find.byKey(const ValueKey('preview-button-k1')));
      await tester.pumpAndSettle();
      expect(downloads.calls, isEmpty);
    });
  });

  group('installation directe', () {
    testWidgets('envoie l’identité complète à /api/downloads/search', (
      tester,
    ) async {
      final repository = FakeCatalogRepository();
      repository.responses['guala lifestyles'] = CatalogSearchPage(
        items: [
          trackResult(
            'k1',
            title: 'Lifestyles',
            artist: 'Guala',
            album: 'Lifestyles',
            durationMs: 127000,
            isrc: 'QZTBF2599924',
          ),
        ],
      );
      final downloads = FakeRemoteDownloadRepository();
      await tester.pumpWidget(makeApp(repository, downloads: downloads));
      await submitSearch(tester, 'guala lifestyles');

      await tester.tap(find.byKey(const ValueKey('install-button-k1')));
      await tester.pump();

      expect(downloads.calls, hasLength(1));
      final call = downloads.calls.single;
      expect(call.query, 'Guala Lifestyles');
      expect(call.title, 'Lifestyles');
      expect(call.artist, 'Guala');
      expect(call.album, 'Lifestyles');
      expect(call.isrc, 'QZTBF2599924');
      expect(call.durationSeconds, 127);
    });

    testWidgets('progression, repli puis succès affichés dans la carte', (
      tester,
    ) async {
      final repository = FakeCatalogRepository();
      repository.responses['guala'] = CatalogSearchPage(
        items: [trackResult('k1', title: 'Lifestyles', artist: 'Guala')],
      );
      final downloads = FakeRemoteDownloadRepository(
        timeline: [
          fakeJob(status: RemoteDownloadStatus.resolving),
          fakeJob(status: RemoteDownloadStatus.downloading, progress: 40),
          fakeJob(
            status: RemoteDownloadStatus.downloading,
            progress: 10,
            attempt: 2,
          ),
          fakeJob(status: RemoteDownloadStatus.importing, progress: 98),
          fakeJob(
            status: RemoteDownloadStatus.completed,
            progress: 100,
            trackId: 42,
          ),
        ],
      );
      await tester.pumpWidget(makeApp(repository, downloads: downloads));
      await submitSearch(tester, 'guala');

      await tester.tap(find.byKey(const ValueKey('install-button-k1')));
      await tester.pump();
      await tester.pumpAndSettle();

      // État terminal : coche verte et confirmation nommant la piste.
      expect(find.byKey(const ValueKey('install-done-k1')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('catalog-install-success')),
        findsOneWidget,
      );
      expect(
        find.text(
          'Guala – Lifestyles a bien été installé dans votre bibliothèque.',
        ),
        findsOneWidget,
      );
      expect(find.text('Lire maintenant'), findsOneWidget);
    });

    testWidgets('repli entre sources annoncé pendant le téléchargement', (
      tester,
    ) async {
      final repository = FakeCatalogRepository();
      repository.responses['guala'] = CatalogSearchPage(
        items: [trackResult('k1', title: 'Lifestyles', artist: 'Guala')],
      );
      final downloads = FakeRemoteDownloadRepository(
        outcome: RemoteDownloadQueued(
          job: fakeJob(
            status: RemoteDownloadStatus.downloading,
            progress: 12,
            attempt: 2,
          ),
          track: const RemoteDownloadTrackOption(
            key: 'k1',
            title: 'Lifestyles',
            artist: 'Guala',
            confidence: 100,
          ),
        ),
      );
      await tester.pumpWidget(makeApp(repository, downloads: downloads));
      await submitSearch(tester, 'guala');

      await tester.tap(find.byKey(const ValueKey('install-button-k1')));
      await tester.pump();

      expect(
        find.text(
          'Première source indisponible, essai d’une autre source…',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('install-progress-k1')), findsOneWidget);
    });

    testWidgets('piste déjà présente : réutilisation, jamais un échec', (
      tester,
    ) async {
      final repository = FakeCatalogRepository();
      repository.responses['guala'] = CatalogSearchPage(
        items: [trackResult('k1', title: 'Lifestyles', artist: 'Guala')],
      );
      final downloads = FakeRemoteDownloadRepository(
        timeline: [
          fakeJob(
            status: RemoteDownloadStatus.completed,
            progress: 100,
            reused: true,
            trackId: 7,
          ),
        ],
      );
      await tester.pumpWidget(makeApp(repository, downloads: downloads));
      await submitSearch(tester, 'guala');

      await tester.tap(find.byKey(const ValueKey('install-button-k1')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('catalog-install-reused')),
        findsOneWidget,
      );
      expect(
        find.text('Ce titre est déjà présent dans votre bibliothèque.'),
        findsWidgets,
      );
      expect(find.byKey(const ValueKey('install-done-k1')), findsOneWidget);
      expect(find.byKey(const ValueKey('install-retry-k1')), findsNothing);
    });

    testWidgets('double clic impossible pendant un job actif', (tester) async {
      final repository = FakeCatalogRepository();
      repository.responses['guala'] = CatalogSearchPage(
        items: [trackResult('k1', title: 'Lifestyles', artist: 'Guala')],
      );
      final downloads = FakeRemoteDownloadRepository(
        timeline: [fakeJob(status: RemoteDownloadStatus.downloading)],
      );
      await tester.pumpWidget(makeApp(repository, downloads: downloads));
      await submitSearch(tester, 'guala');

      await tester.tap(find.byKey(const ValueKey('install-button-k1')));
      await tester.pump();

      // Le bouton d'installation a disparu au profit du spinner désactivé.
      expect(find.byKey(const ValueKey('install-button-k1')), findsNothing);
      final busy = find.byKey(const ValueKey('install-busy-k1'));
      expect(busy, findsOneWidget);
      expect(tester.widget<IconButton>(busy).onPressed, isNull);
      await tester.tap(busy, warnIfMissed: false);
      await tester.pump();
      expect(downloads.calls, hasLength(1));
    });

    testWidgets('échec : icône Réessayer, puis relance réelle', (tester) async {
      final repository = FakeCatalogRepository();
      repository.responses['guala'] = CatalogSearchPage(
        items: [trackResult('k1', title: 'Lifestyles', artist: 'Guala')],
      );
      final downloads = FakeRemoteDownloadRepository(
        timeline: [
          fakeJob(
            status: RemoteDownloadStatus.failed,
            errorMessage: 'Aucune source n’a abouti.',
          ),
        ],
      );
      await tester.pumpWidget(makeApp(repository, downloads: downloads));
      await submitSearch(tester, 'guala');

      await tester.tap(find.byKey(const ValueKey('install-button-k1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('install-retry-k1')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('install-retry-k1')));
      await tester.pumpAndSettle();
      expect(downloads.calls, hasLength(2));
    });

    testWidgets('retour sur l’écran : le job actif est retrouvé', (
      tester,
    ) async {
      final repository = FakeCatalogRepository();
      repository.responses['guala'] = CatalogSearchPage(
        items: [trackResult('k1', title: 'Lifestyles', artist: 'Guala')],
      );
      final downloads = FakeRemoteDownloadRepository(
        existingJobs: [
          fakeJob(
            id: 'job-restored',
            status: RemoteDownloadStatus.downloading,
            progress: 55,
          ),
        ],
        timeline: [
          fakeJob(
            id: 'job-restored',
            status: RemoteDownloadStatus.downloading,
            progress: 60,
          ),
        ],
      );
      await tester.pumpWidget(makeApp(repository, downloads: downloads));
      // Pas de `pumpAndSettle` : la reprise d'état affiche un indicateur de
      // progression, qui ne se stabilise jamais par construction.
      await tester.enterText(
        find.byKey(const ValueKey('catalog-search-field')),
        'guala',
      );
      await tester.pump(
        kCatalogSearchDebounce + const Duration(milliseconds: 80),
      );
      for (var i = 0; i < 5; i += 1) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(find.byKey(const ValueKey('install-busy-k1')), findsOneWidget);
      // Aucune nouvelle installation n'a été déclenchée par la reprise d'état.
      expect(downloads.calls, isEmpty);
    });
  });
}
