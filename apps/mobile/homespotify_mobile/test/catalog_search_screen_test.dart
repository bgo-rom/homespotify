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

import 'support/fake_audio_player.dart';

class FakeCatalogRepository implements CatalogSearchRepository {
  final Map<String, CatalogSearchPage> responses = {};
  CatalogSearchException? failWith;

  @override
  Future<CatalogSearchPage> search({
    required String query,
    required CatalogEntityType type,
    String? cursor,
    int limit = 20,
  }) async {
    final error = failWith;
    if (error != null) throw error;
    return responses['${type.wireName}:$query'] ??
        const CatalogSearchPage(items: []);
  }

  @override
  Future<CatalogArtistDetail> fetchArtist(CatalogEntityRef reference) =>
      throw UnimplementedError();

  @override
  Future<CatalogAlbumPage> fetchArtistAlbums(
    CatalogEntityRef reference, {
    String? cursor,
  }) => throw UnimplementedError();

  @override
  Future<CatalogAlbumDetail> fetchAlbum(CatalogEntityRef reference) =>
      throw UnimplementedError();

  @override
  Future<List<ProviderStatus>> fetchProviders() async => const [];
}

CatalogResult trackResult(
  String key, {
  String title = 'Chanson',
  String artist = 'Artiste',
  List<PlatformLink> links = const [],
  CatalogPreview? preview,
}) {
  return CatalogResult(
    canonicalKey: key,
    entityType: CatalogEntityType.track,
    title: title,
    artistNames: [artist],
    album: 'Album',
    durationMs: 201000,
    links: links,
    preview: preview,
  );
}

Widget makeApp(
  FakeCatalogRepository repository, {
  List<Track> library = const [],
}) {
  return ProviderScope(
    overrides: [
      catalogSearchApiProvider.overrideWithValue(repository),
      libraryProvider.overrideWith((ref) async => library),
      catalogPreviewPlayerFactoryProvider.overrideWithValue(
        FakeAudioPlayer.new,
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
  testWidgets('état initial : message d’accueil, aucune requête', (
    tester,
  ) async {
    await tester.pumpWidget(makeApp(FakeCatalogRepository()));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('catalog-search-initial')),
      findsOneWidget,
    );
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

  testWidgets('résultats affichés avec badges plateformes confirmées '
      'et UNKNOWN jamais montré', (tester) async {
    final repository = FakeCatalogRepository();
    repository.responses['track:muse'] = CatalogSearchPage(
      items: [
        trackResult(
          'k1',
          title: 'Uprising',
          artist: 'Muse',
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
            PlatformLink(
              platform: 'deezer',
              status: PlatformAvailability.providerDisabled,
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(makeApp(repository));
    await submitSearch(tester, 'muse');
    expect(find.text('Uprising'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('platform-badge-spotify')),
      findsOneWidget,
    );
    // UNKNOWN et PROVIDER_DISABLED : aucun badge, aucun « Indisponible ».
    expect(find.byKey(const ValueKey('platform-badge-bandcamp')), findsNothing);
    expect(find.byKey(const ValueKey('platform-badge-deezer')), findsNothing);
    expect(find.textContaining('Indisponible'), findsNothing);
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
    // Retry après rétablissement.
    repository.failWith = null;
    repository.responses['track:muse'] = CatalogSearchPage(
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
    repository.responses['track:uprising'] = CatalogSearchPage(
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
    // Piste possédée : pas de bouton « Demander ».
    expect(find.byKey(const ValueKey('request-button-k1')), findsNothing);
  });

  testWidgets('bouton demande ouvre la bottom sheet sans champ userId', (
    tester,
  ) async {
    final repository = FakeCatalogRepository();
    repository.responses['track:muse'] = CatalogSearchPage(
      items: [trackResult('k1', title: 'Uprising', artist: 'Muse')],
    );
    await tester.pumpWidget(makeApp(repository));
    await submitSearch(tester, 'muse');
    await tester.tap(find.byKey(const ValueKey('request-button-k1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('catalog-request-send')), findsOneWidget);
    expect(find.byKey(const ValueKey('catalog-request-note')), findsOneWidget);
    // Aucun champ d'identifiant de compte dans la feuille.
    expect(find.textContaining('userId'), findsNothing);
  });

  testWidgets('bannière de résultats partiels quand un provider est dégradé', (
    tester,
  ) async {
    final repository = FakeCatalogRepository();
    repository.responses['track:muse'] = CatalogSearchPage(
      items: [trackResult('k1')],
      providers: const [
        ProviderStatus(id: 'spotify', status: 'OK'),
        ProviderStatus(id: 'musicbrainz', status: 'DEGRADED'),
      ],
    );
    await tester.pumpWidget(makeApp(repository));
    await submitSearch(tester, 'muse');
    expect(
      find.byKey(const ValueKey('catalog-partial-banner')),
      findsOneWidget,
    );
  });

  testWidgets('bouton preview affiché uniquement quand une preview existe', (
    tester,
  ) async {
    final repository = FakeCatalogRepository();
    repository.responses['track:muse'] = CatalogSearchPage(
      items: [
        trackResult(
          'avec',
          title: 'Avec aperçu',
          preview: const CatalogPreview(
            provider: 'apple_music',
            url: 'https://p.example/a.m4a',
          ),
        ),
        trackResult('sans', title: 'Sans aperçu'),
      ],
    );
    await tester.pumpWidget(makeApp(repository));
    await submitSearch(tester, 'muse');
    expect(find.byKey(const ValueKey('preview-button-avec')), findsOneWidget);
    expect(find.byKey(const ValueKey('preview-button-sans')), findsNothing);
  });

  testWidgets('changement d’onglet vers Albums', (tester) async {
    final repository = FakeCatalogRepository();
    repository.responses['album:muse'] = const CatalogSearchPage(
      items: [
        CatalogResult(
          canonicalKey: 'al1',
          entityType: CatalogEntityType.album,
          title: 'The Resistance',
          artistNames: ['Muse'],
          trackCount: 11,
        ),
      ],
    );
    await tester.pumpWidget(makeApp(repository));
    await tester.tap(find.byKey(const ValueKey('catalog-tab-album')));
    await tester.pumpAndSettle();
    await submitSearch(tester, 'muse');
    expect(find.text('The Resistance'), findsOneWidget);
    expect(find.textContaining('11 pistes'), findsOneWidget);
  });
}
