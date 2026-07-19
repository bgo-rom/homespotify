import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:homespotify_mobile/src/features/library/data/favorites_api.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_favorites.dart';

void main() {
  test('backend source de vérité et rollback si écriture refusée', () async {
    final repository = _MemoryFavoritesRepository(<int>{2});
    final container = ProviderContainer(
      overrides: [favoritesApiProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);

    expect(await container.read(favoriteTrackIdsProvider.future), <int>{2});

    await container.read(favoriteTrackIdsProvider.notifier).toggle(1);
    expect(container.read(favoriteTrackIdsProvider).requireValue, <int>{1, 2});
    expect(repository.ids, <int>{1, 2});

    repository.failWrites = true;
    await expectLater(
      container.read(favoriteTrackIdsProvider.notifier).toggle(2),
      throwsStateError,
    );
    expect(container.read(favoriteTrackIdsProvider).requireValue, <int>{1, 2});
  });

  test('deux comptes chargent des favoris distincts', () async {
    final first = ProviderContainer(
      overrides: [
        favoritesApiProvider.overrideWithValue(
          _MemoryFavoritesRepository(<int>{1}),
        ),
      ],
    );
    final second = ProviderContainer(
      overrides: [
        favoritesApiProvider.overrideWithValue(
          _MemoryFavoritesRepository(<int>{2}),
        ),
      ],
    );
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    expect(await first.read(favoriteTrackIdsProvider.future), <int>{1});
    expect(await second.read(favoriteTrackIdsProvider.future), <int>{2});
  });
}

class _MemoryFavoritesRepository implements FavoritesRepository {
  _MemoryFavoritesRepository(Set<int> initial) : ids = Set<int>.of(initial);

  Set<int> ids;
  bool failWrites = false;

  @override
  Future<Set<int>> fetch() async => Set<int>.of(ids);

  @override
  Future<void> add(int trackId) async {
    if (failWrites) throw StateError('refus backend');
    ids.add(trackId);
  }

  @override
  Future<void> remove(int trackId) async {
    if (failWrites) throw StateError('refus backend');
    ids.remove(trackId);
  }
}
