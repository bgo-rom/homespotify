import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homespotify_mobile/src/features/catalog_search/application/catalog_search_controller.dart';
import 'package:homespotify_mobile/src/features/catalog_search/data/catalog_search_api.dart';
import 'package:homespotify_mobile/src/features/catalog_search/domain/catalog_models.dart';

CatalogResult result(String key, {String? title, String? isrc}) {
  return CatalogResult(
    canonicalKey: key,
    entityType: CatalogEntityType.track,
    title: title ?? 'Titre $key',
    artistNames: const ['Artiste'],
    isrc: isrc,
  );
}

class FakeCatalogRepository implements CatalogSearchRepository {
  final List<({String query, CatalogEntityType type, String? cursor})> calls =
      [];
  final Map<String, CatalogSearchPage> responses = {};
  CatalogSearchException? failWith;
  Completer<CatalogSearchPage>? pending;

  @override
  Future<CatalogSearchPage> search({
    required String query,
    required CatalogEntityType type,
    String? cursor,
    int limit = 20,
  }) async {
    calls.add((query: query, type: type, cursor: cursor));
    final blocking = pending;
    if (blocking != null) {
      pending = null;
      return blocking.future;
    }
    final error = failWith;
    if (error != null) throw error;
    return responses['${type.wireName}:$query:${cursor ?? ''}'] ??
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

(ProviderContainer, FakeCatalogRepository) makeContainer() {
  final repository = FakeCatalogRepository();
  final container = ProviderContainer(
    overrides: [catalogSearchApiProvider.overrideWithValue(repository)],
  );
  return (container, repository);
}

Future<void> waitDebounce() => Future<void>.delayed(
  kCatalogSearchDebounce + const Duration(milliseconds: 80),
);

void main() {
  test('état initial : aucune recherche, aucun résultat', () {
    final (container, repository) = makeContainer();
    final state = container.read(catalogSearchProvider);
    expect(state.searched, isFalse);
    expect(state.results, isEmpty);
    expect(repository.calls, isEmpty);
    container.dispose();
  });

  test('debounce : une seule requête après une saisie rapide', () async {
    final (container, repository) = makeContainer();
    final controller = container.read(catalogSearchProvider.notifier);
    repository.responses['track:daft punk:'] = CatalogSearchPage(
      items: [result('k1')],
    );
    controller.onQueryChanged('da');
    controller.onQueryChanged('daft');
    controller.onQueryChanged('daft punk');
    expect(repository.calls, isEmpty); // rien avant le délai
    await waitDebounce();
    expect(repository.calls, hasLength(1));
    expect(repository.calls.single.query, 'daft punk');
    expect(container.read(catalogSearchProvider).results, hasLength(1));
    container.dispose();
  });

  test('recherche trop courte : aucune requête, résultats vidés', () async {
    final (container, repository) = makeContainer();
    final controller = container.read(catalogSearchProvider.notifier);
    controller.onQueryChanged('a');
    await waitDebounce();
    expect(repository.calls, isEmpty);
    expect(container.read(catalogSearchProvider).isQueryTooShort, isTrue);
    container.dispose();
  });

  test('réponse périmée ignorée : seule la dernière recherche gagne', () async {
    final (container, repository) = makeContainer();
    final controller = container.read(catalogSearchProvider.notifier);
    // Première recherche : réponse BLOQUÉE (résolue après la seconde).
    final slow = Completer<CatalogSearchPage>();
    repository.pending = slow;
    controller.onQueryChanged('ancienne');
    await waitDebounce();
    // Seconde recherche : réponse immédiate.
    repository.responses['track:nouvelle:'] = CatalogSearchPage(
      items: [result('nouveau')],
    );
    controller.onQueryChanged('nouvelle');
    await waitDebounce();
    expect(
      container.read(catalogSearchProvider).results.single.canonicalKey,
      'nouveau',
    );
    // L'ancienne réponse arrive TROP TARD : elle ne doit rien écraser.
    slow.complete(CatalogSearchPage(items: [result('perime')]));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      container.read(catalogSearchProvider).results.single.canonicalKey,
      'nouveau',
    );
    container.dispose();
  });

  test('changement d’onglet relance immédiatement avec le bon type', () async {
    final (container, repository) = makeContainer();
    final controller = container.read(catalogSearchProvider.notifier);
    repository.responses['track:muse:'] = CatalogSearchPage(
      items: [result('t')],
    );
    controller.onQueryChanged('muse');
    await waitDebounce();
    controller.onTypeChanged(CatalogEntityType.album);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(repository.calls.last.type, CatalogEntityType.album);
    container.dispose();
  });

  test('erreur : message + résultats vides, retry relance', () async {
    final (container, repository) = makeContainer();
    final controller = container.read(catalogSearchProvider.notifier);
    repository.failWith = const CatalogSearchException('Serveur injoignable');
    controller.onQueryChanged('radiohead');
    await waitDebounce();
    var state = container.read(catalogSearchProvider);
    expect(state.error, 'Serveur injoignable');
    expect(state.results, isEmpty);
    repository.failWith = null;
    repository.responses['track:radiohead:'] = CatalogSearchPage(
      items: [result('ok')],
    );
    await controller.retry();
    state = container.read(catalogSearchProvider);
    expect(state.error, isNull);
    expect(state.results, hasLength(1));
    container.dispose();
  });

  test('résultats partiels : provider DEGRADED signalé sans erreur', () async {
    final (container, repository) = makeContainer();
    final controller = container.read(catalogSearchProvider.notifier);
    repository.responses['track:muse:'] = CatalogSearchPage(
      items: [result('t')],
      providers: const [
        ProviderStatus(id: 'spotify', status: 'OK'),
        ProviderStatus(id: 'musicbrainz', status: 'DEGRADED'),
      ],
    );
    controller.onQueryChanged('muse');
    await waitDebounce();
    final state = container.read(catalogSearchProvider);
    expect(state.partialResults, isTrue);
    expect(state.error, isNull);
    container.dispose();
  });

  test('pagination : loadMore ajoute sans doublon de clé', () async {
    final (container, repository) = makeContainer();
    final controller = container.read(catalogSearchProvider.notifier);
    repository.responses['track:muse:'] = CatalogSearchPage(
      items: [result('a'), result('b')],
      nextCursor: 'c1',
    );
    repository.responses['track:muse:c1'] = CatalogSearchPage(
      items: [result('b'), result('c')],
    );
    controller.onQueryChanged('muse');
    await waitDebounce();
    await controller.loadMore();
    final keys = container
        .read(catalogSearchProvider)
        .results
        .map((item) => item.canonicalKey)
        .toList();
    expect(keys, ['a', 'b', 'c']);
    expect(container.read(catalogSearchProvider).nextCursor, isNull);
    container.dispose();
  });

  test('UNKNOWN n’est jamais un badge positif', () {
    const unknown = PlatformLink(
      platform: 'deezer',
      status: PlatformAvailability.unknown,
    );
    const disabled = PlatformLink(
      platform: 'tidal',
      status: PlatformAvailability.providerDisabled,
    );
    const confirmed = PlatformLink(
      platform: 'spotify',
      status: PlatformAvailability.confirmed,
    );
    expect(unknown.status.isPositive, isFalse);
    expect(disabled.status.isPositive, isFalse);
    expect(confirmed.status.isPositive, isTrue);
  });

  test('le modèle client ne transporte aucun secret', () {
    final parsed = CatalogSearchPage.fromJson(const {
      'items': [
        {
          'canonicalKey': 'isrc:X',
          'entityType': 'track',
          'title': 'T',
          'artists': [
            {'name': 'A'},
          ],
          'providerReferences': [
            {
              'provider': 'spotify',
              'entityType': 'track',
              'externalId': 'id1',
              'externalUrl': 'https://open.spotify.com/track/id1',
            },
          ],
        },
      ],
      'providers': [
        {'id': 'spotify', 'status': 'OK'},
      ],
    });
    expect(parsed.items.single.references.single.externalId, 'id1');
    // Un canonicalKey et des URLs https : rien d'autre ne sort du backend.
    expect(
      parsed.items.single.references.single.externalUrl,
      startsWith('https://'),
    );
  });
}
