import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../catalog/data/catalog_api.dart';
import '../data/library_api.dart';
import '../presentation/library_favorites.dart';

/// État d'appartenance d'UNE piste à la bibliothèque du COMPTE CONNECTÉ.
class TrackMembership {
  const TrackMembership({this.inMyLibrary, this.loading = false, this.error});

  /// null tant que l'état réel est inconnu → aucun libellé menteur affiché.
  final bool? inMyLibrary;
  final bool loading;
  final String? error;
}

/// Lecture de l'appartenance RÉELLE côté serveur (`GET /api/library/tracks/:id`,
/// autorité = `user_tracks`). `FutureProvider` : le chargement est déclenché par
/// l'observation, jamais par une mutation depuis un `build`.
final remoteTrackMembershipProvider = FutureProvider.family<bool, int>((
  ref,
  trackId,
) {
  return ref.watch(catalogApiProvider).isInMyLibrary(trackId);
});

/// Contrôleur CENTRAL et UNIQUE des actions « Ajouter / Supprimer de ma
/// bibliothèque ». Détient les surcharges locales par `trackId` (mise à jour
/// optimiste, résultat final, rollback).
///
/// SOURCE D'AUTORITÉ : `user_tracks` du compte connecté. L'état n'est JAMAIS
/// déduit de l'écran d'origine, du rôle OWNER, de la lisibilité, du catalogue
/// global, de la file de lecture ni d'un libellé précédent — une piste peut être
/// jouée depuis le catalogue sans appartenir à la bibliothèque.
///
/// Aucune action ici ne touche la lecture : ajouter/retirer n'arrête jamais
/// l'audio, ne vide pas la file et ne change pas le `currentMediaItem`.
class TrackLibraryMembershipController
    extends Notifier<Map<int, TrackMembership>> {
  @override
  Map<int, TrackMembership> build() => const {};

  void _set(int trackId, TrackMembership value) {
    state = {...state, trackId: value};
  }

  void _clear(int trackId) {
    final next = {...state}..remove(trackId);
    state = next;
  }

  /// Ajoute la piste à la bibliothèque du compte courant (idempotent).
  /// Lève [CatalogApiException] en cas d'échec, APRÈS rollback.
  Future<void> addToMyLibrary(int trackId) async {
    _set(trackId, const TrackMembership(inMyLibrary: true, loading: true));
    try {
      await ref.read(catalogApiProvider).addToLibrary(trackId);
      _set(trackId, const TrackMembership(inMyLibrary: true));
      _syncDependents(trackId);
      logUi('piste ajoutée à la bibliothèque track=$trackId');
    } on CatalogApiException catch (error) {
      // Rollback : on retombe sur l'état serveur réel, jamais un faux succès.
      _clear(trackId);
      ref.invalidate(remoteTrackMembershipProvider(trackId));
      logError('ajout bibliothèque track=$trackId échoué', error: error);
      rethrow;
    }
  }

  /// Retire la piste de la bibliothèque du compte courant.
  ///
  /// Retourne `true` si une suppression RÉELLE a eu lieu (message légitime),
  /// `false` si la piste n'y était pas — l'état est alors simplement
  /// resynchronisé sur « absente », SANS faux message de suppression.
  /// Lève [LibraryApiException] en cas d'échec réel, APRÈS rollback.
  Future<bool> removeFromMyLibrary(int trackId) async {
    _set(trackId, const TrackMembership(inMyLibrary: false, loading: true));
    try {
      final removed = await ref.read(libraryApiProvider).deleteTrack(trackId);
      _set(trackId, const TrackMembership(inMyLibrary: false));
      _syncDependents(trackId);
      if (removed) logUi('piste retirée de la bibliothèque track=$trackId');
      return removed;
    } on LibraryApiException catch (error) {
      _clear(trackId);
      ref.invalidate(remoteTrackMembershipProvider(trackId));
      logError('suppression bibliothèque track=$trackId échouée', error: error);
      rethrow;
    }
  }

  /// Rafraîchit UNIQUEMENT les données concernées — jamais toute l'application,
  /// jamais le lecteur.
  void _syncDependents(int trackId) {
    ref.invalidate(remoteTrackMembershipProvider(trackId));
    ref.invalidate(libraryProvider);
    ref.invalidate(favoriteTrackIdsProvider);
    ref.invalidate(catalogRecentProvider);
  }
}

final trackLibraryMembershipProvider =
    NotifierProvider<
      TrackLibraryMembershipController,
      Map<int, TrackMembership>
    >(TrackLibraryMembershipController.new);

/// Appartenance d'une piste pour le compte connecté :
/// `ref.watch(trackMembershipProvider(trackId))`.
///
/// Priorité à la surcharge locale (optimiste / résultat d'action), sinon état
/// serveur. Recalculé au changement de compte (providers invalidés au logout).
final trackMembershipProvider = Provider.family<TrackMembership, int>((
  ref,
  trackId,
) {
  final local = ref.watch(trackLibraryMembershipProvider)[trackId];
  if (local != null) return local;
  return ref
      .watch(remoteTrackMembershipProvider(trackId))
      .when(
        data: (value) => TrackMembership(inMyLibrary: value),
        loading: () => const TrackMembership(loading: true),
        error: (error, _) => TrackMembership(error: '$error'),
      );
});
