import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homespotify_mobile/src/features/catalog/data/catalog_api.dart';
import 'package:homespotify_mobile/src/features/library/application/track_library_membership.dart';
import 'package:homespotify_mobile/src/features/library/data/library_api.dart';

/// L'action « Ajouter / Supprimer de ma bibliothèque » dépend STRICTEMENT de
/// l'appartenance réelle (`user_tracks`) du compte connecté.

class _FakeCatalogApi implements CatalogRepository {
  _FakeCatalogApi({this.inLibrary = false});

  bool inLibrary;
  int addCalls = 0;
  CatalogApiException? nextAddError;

  @override
  Future<List<CatalogEntry>> fetchRecent({int limit = 20}) async => const [];

  @override
  Future<bool> isInMyLibrary(int trackId) async => inLibrary;

  @override
  Future<bool> addToLibrary(int trackId) async {
    final error = nextAddError;
    if (error != null) {
      nextAddError = null;
      throw error;
    }
    addCalls += 1;
    final created = !inLibrary;
    inLibrary = true;
    return created;
  }
}

class _FakeLibraryApi extends LibraryApi {
  _FakeLibraryApi(this._catalog) : super(Dio(), '');

  final _FakeCatalogApi _catalog;
  int deleteCalls = 0;
  LibraryApiException? nextDeleteError;

  @override
  Future<bool> deleteTrack(int id) async {
    final error = nextDeleteError;
    if (error != null) {
      nextDeleteError = null;
      throw error;
    }
    deleteCalls += 1;
    // Miroir du backend : `false` si la piste n'était pas dans la bibliothèque.
    final removed = _catalog.inLibrary;
    _catalog.inLibrary = false;
    return removed;
  }
}

ProviderContainer _makeContainer(
  _FakeCatalogApi catalog,
  _FakeLibraryApi library,
) {
  final container = ProviderContainer(
    overrides: [
      catalogApiProvider.overrideWithValue(catalog),
      libraryApiProvider.overrideWithValue(library),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('appartenance réelle (source d’autorité user_tracks)', () {
    test('piste du catalogue ABSENTE → inMyLibrary = false', () async {
      final catalog = _FakeCatalogApi(inLibrary: false);
      final container = _makeContainer(catalog, _FakeLibraryApi(catalog));

      await container.read(remoteTrackMembershipProvider(1).future);
      expect(container.read(trackMembershipProvider(1)).inMyLibrary, isFalse);
    });

    test('piste PRÉSENTE → inMyLibrary = true', () async {
      final catalog = _FakeCatalogApi(inLibrary: true);
      final container = _makeContainer(catalog, _FakeLibraryApi(catalog));

      await container.read(remoteTrackMembershipProvider(1).future);
      expect(container.read(trackMembershipProvider(1)).inMyLibrary, isTrue);
    });
  });

  group('ajout', () {
    test('ajoute puis bascule à true (idempotent, un seul appel)', () async {
      final catalog = _FakeCatalogApi(inLibrary: false);
      final container = _makeContainer(catalog, _FakeLibraryApi(catalog));
      await container.read(remoteTrackMembershipProvider(1).future);

      await container
          .read(trackLibraryMembershipProvider.notifier)
          .addToMyLibrary(1);

      expect(container.read(trackMembershipProvider(1)).inMyLibrary, isTrue);
      expect(catalog.addCalls, 1);
    });

    test('échec → rollback, aucun faux succès', () async {
      final catalog = _FakeCatalogApi(inLibrary: false);
      final container = _makeContainer(catalog, _FakeLibraryApi(catalog));
      await container.read(remoteTrackMembershipProvider(1).future);
      catalog.nextAddError = const CatalogApiException('Réseau indisponible');

      await expectLater(
        container
            .read(trackLibraryMembershipProvider.notifier)
            .addToMyLibrary(1),
        throwsA(isA<CatalogApiException>()),
      );
      // L'état optimiste est annulé : la piste reste absente.
      await container.read(remoteTrackMembershipProvider(1).future);
      expect(container.read(trackMembershipProvider(1)).inMyLibrary, isFalse);
    });
  });

  group('suppression', () {
    test('piste présente → suppression RÉELLE (true) et état false', () async {
      final catalog = _FakeCatalogApi(inLibrary: true);
      final library = _FakeLibraryApi(catalog);
      final container = _makeContainer(catalog, library);
      await container.read(remoteTrackMembershipProvider(1).future);

      final removed = await container
          .read(trackLibraryMembershipProvider.notifier)
          .removeFromMyLibrary(1);

      expect(removed, isTrue); // → message « Supprimé » légitime
      expect(container.read(trackMembershipProvider(1)).inMyLibrary, isFalse);
    });

    test('piste ABSENTE → false : aucun faux message de suppression', () async {
      // Cas du bug : lecture depuis « Ajouts récents », aucune association.
      final catalog = _FakeCatalogApi(inLibrary: false);
      final library = _FakeLibraryApi(catalog);
      final container = _makeContainer(catalog, library);
      await container.read(remoteTrackMembershipProvider(1).future);

      final removed = await container
          .read(trackLibraryMembershipProvider.notifier)
          .removeFromMyLibrary(1);

      expect(removed, isFalse); // → l'UI n'affiche AUCUN « Supprimé »
      expect(container.read(trackMembershipProvider(1)).inMyLibrary, isFalse);
    });

    test('échec réseau → rollback, aucun faux succès', () async {
      final catalog = _FakeCatalogApi(inLibrary: true);
      final library = _FakeLibraryApi(catalog);
      final container = _makeContainer(catalog, library);
      await container.read(remoteTrackMembershipProvider(1).future);
      library.nextDeleteError = LibraryApiException('Serveur injoignable');

      await expectLater(
        container
            .read(trackLibraryMembershipProvider.notifier)
            .removeFromMyLibrary(1),
        throwsA(isA<LibraryApiException>()),
      );
      // Rollback : la piste est toujours dans la bibliothèque.
      await container.read(remoteTrackMembershipProvider(1).future);
      expect(container.read(trackMembershipProvider(1)).inMyLibrary, isTrue);
    });
  });

  group('changement de compte', () {
    test('l’état est recalculé pour le nouveau userId', () async {
      // skibidi possède la piste…
      final catalog = _FakeCatalogApi(inLibrary: true);
      final container = _makeContainer(catalog, _FakeLibraryApi(catalog));
      await container.read(remoteTrackMembershipProvider(1).future);
      expect(container.read(trackMembershipProvider(1)).inMyLibrary, isTrue);

      // …le OWNER se connecte : purge (invalidation au logout) + recalcul.
      catalog.inLibrary = false;
      container.invalidate(trackLibraryMembershipProvider);
      container.invalidate(remoteTrackMembershipProvider);
      await container.read(remoteTrackMembershipProvider(1).future);

      expect(container.read(trackMembershipProvider(1)).inMyLibrary, isFalse);
    });
  });
}
