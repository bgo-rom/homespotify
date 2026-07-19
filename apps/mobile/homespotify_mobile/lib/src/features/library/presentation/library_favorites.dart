import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/network/api_client.dart';
import '../data/favorites_api.dart';
import '../data/library_api.dart';
import '../domain/track.dart';

/// Favoris servis par le backend (source de vérité par compte). Le JSON local
/// n'est plus utilisé : au logout, l'invalidation de ce provider vide les
/// favoris de l'ancien compte en mémoire.
final favoritesApiProvider = Provider<FavoritesRepository>(
  (ref) => FavoritesApi(ref.watch(apiClientProvider)),
);

class FavoritesController extends AsyncNotifier<Set<int>> {
  bool _saving = false;

  @override
  Future<Set<int>> build() async {
    final ids = await ref.watch(favoritesApiProvider).fetch();
    return Set<int>.unmodifiable(ids);
  }

  Future<void> toggle(int trackId) async {
    final current = state.asData?.value;
    if (current == null || _saving) return;

    final wasFavorite = current.contains(trackId);
    final next = Set<int>.of(current);
    if (wasFavorite) {
      next.remove(trackId);
    } else {
      next.add(trackId);
    }
    final immutableNext = Set<int>.unmodifiable(next);

    _saving = true;
    // Optimiste : l'UI réagit tout de suite, rollback si le backend refuse.
    state = AsyncData(immutableNext);
    try {
      final api = ref.read(favoritesApiProvider);
      if (wasFavorite) {
        await api.remove(trackId);
      } else {
        await api.add(trackId);
      }
      logLibrary(
        '${wasFavorite ? 'retrait' : 'ajout'} favori: trackId=$trackId',
      );
    } catch (error, stackTrace) {
      state = AsyncData(current);
      logError(
        'échec persistance favori: trackId=$trackId',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    } finally {
      _saving = false;
    }
  }
}

final favoriteTrackIdsProvider =
    AsyncNotifierProvider<FavoritesController, Set<int>>(
      FavoritesController.new,
      name: 'favoriteTrackIds',
    );

final isFavoriteProvider = Provider.family<bool, int>((ref, trackId) {
  return ref.watch(favoriteTrackIdsProvider).asData?.value.contains(trackId) ??
      false;
});

/// Pistes favorites dans l'ordre courant de la bibliothèque chargée.
final favoriteTracksProvider = Provider<List<Track>>((ref) {
  final tracks = ref.watch(libraryProvider).asData?.value ?? const <Track>[];
  final ids =
      ref.watch(favoriteTrackIdsProvider).asData?.value ?? const <int>{};
  return tracks
      .where((track) => ids.contains(track.id))
      .toList(growable: false);
});
