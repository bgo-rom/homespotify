import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../library/data/library_api.dart';
import '../../library/domain/track.dart';
import '../../library/presentation/library_albums.dart';
import '../../library/presentation/library_artists.dart';
import '../../listening/data/listening_activity_api.dart';
import '../../listening/domain/listening_activity.dart';

/// Nombre d'éléments affichés par carrousel de l'accueil.
const int kHomeSectionLimit = 12;

/// Sessions d'écoute examinées pour les sections dérivées de l'historique.
const int kHomeHistoryWindow = 200;

/// Pistes de la bibliothèque, les plus récemment ajoutées d'abord.
///
/// **Approximation assumée** : la bibliothèque n'expose pas de date d'ajout.
/// L'identifiant est attribué par la base dans l'ordre d'insertion, donc un id
/// plus grand = ajout plus récent. C'est exact tant que les identifiants ne
/// sont pas réattribués — ce que le backend ne fait pas.
final recentlyAddedTracksProvider = Provider<List<Track>>((ref) {
  final tracks = ref.watch(libraryProvider).asData?.value ?? const <Track>[];
  final sorted = [...tracks]..sort((a, b) => b.id.compareTo(a.id));
  return List<Track>.unmodifiable(sorted.take(kHomeSectionLimit));
});

/// Albums de la bibliothèque, les plus récemment complétés d'abord.
///
/// Un album est daté par sa piste la plus récente : ajouter un titre à un
/// album ancien le fait remonter, ce qui correspond à l'attente (« ce sur quoi
/// j'ai travaillé récemment »).
final recentAlbumsProvider = Provider<List<AlbumSummary>>((ref) {
  final albums = ref.watch(albumsProvider);
  final ranked = [...albums]
    ..sort((a, b) => _newestTrackId(b).compareTo(_newestTrackId(a)));
  return List<AlbumSummary>.unmodifiable(ranked.take(kHomeSectionLimit));
});

int _newestTrackId(AlbumSummary album) =>
    album.tracks.fold<int>(0, (best, track) => max(best, track.id));

/// Historique d'écoute brut, partagé par les sections qui en dérivent.
///
/// Une seule requête sert « Récemment écoutés » et « Artistes fréquents » :
/// deux appels séparés doubleraient le trafic pour la même donnée.
final listeningHistoryProvider = FutureProvider<List<ListeningSession>>((
  ref,
) async {
  final page = await ref.watch(listeningActivityApiProvider).fetchActivity();
  return page.items;
});

/// Pistes réécoutables récemment jouées, sans doublon, les plus récentes
/// d'abord.
///
/// Croisé avec la bibliothèque : l'historique porte des identifiants, mais
/// seule une piste encore présente est lisible. Une piste supprimée depuis
/// disparaît donc de la section au lieu d'y rester en panne.
final recentlyPlayedTracksProvider = Provider<List<Track>>((ref) {
  final sessions =
      ref.watch(listeningHistoryProvider).asData?.value ??
      const <ListeningSession>[];
  final library = ref.watch(libraryProvider).asData?.value ?? const <Track>[];
  if (sessions.isEmpty || library.isEmpty) return const [];

  final byId = {for (final track in library) track.id: track};
  final seen = <int>{};
  final result = <Track>[];

  for (final session in sessions) {
    final track = byId[session.track.id];
    if (track == null) continue;
    if (!seen.add(track.id)) continue;
    result.add(track);
    if (result.length >= kHomeSectionLimit) break;
  }
  return List<Track>.unmodifiable(result);
});

/// Artistes les plus écoutés, du plus fréquent au moins fréquent.
///
/// Compte les **sessions qualifiées** uniquement : un titre lancé puis passé
/// en deux secondes ne doit pas peser autant qu'une écoute réelle. À égalité,
/// l'artiste dont l'écoute est la plus récente passe devant.
final frequentArtistsProvider = Provider<List<ArtistSummary>>((ref) {
  final sessions =
      ref.watch(listeningHistoryProvider).asData?.value ??
      const <ListeningSession>[];
  final artists = ref.watch(artistsProvider);
  if (sessions.isEmpty || artists.isEmpty) return const [];

  final counts = <String, int>{};
  final lastPlayed = <String, DateTime>{};

  for (final session in sessions.take(kHomeHistoryWindow)) {
    if (!session.qualifiedPlay) continue;
    final key = artistKeyForName(session.track.artist);
    if (key == unknownArtistKey) continue;
    counts[key] = (counts[key] ?? 0) + 1;
    final previous = lastPlayed[key];
    if (previous == null || session.lastActivityAt.isAfter(previous)) {
      lastPlayed[key] = session.lastActivityAt;
    }
  }
  if (counts.isEmpty) return const [];

  final byKey = {
    for (final artist in artists) artistKeyForName(artist.name): artist,
  };

  final ranked =
      counts.entries.where((entry) => byKey.containsKey(entry.key)).toList()
        ..sort((a, b) {
          final byCount = b.value.compareTo(a.value);
          if (byCount != 0) return byCount;
          final aDate = lastPlayed[a.key];
          final bDate = lastPlayed[b.key];
          if (aDate == null || bDate == null) return 0;
          return bDate.compareTo(aDate);
        });

  return List<ArtistSummary>.unmodifiable(
    ranked.map((entry) => byKey[entry.key]!).take(kHomeSectionLimit),
  );
});

/// File de lecture aléatoire sur TOUTE la bibliothèque.
///
/// Le mélange est fait ici plutôt que délégué au mode shuffle du lecteur :
/// l'utilisateur attend un ordre déjà tiré au moment où il appuie, et la file
/// visible doit correspondre à ce qui sera joué.
List<Track> shuffledLibraryQueue(List<Track> tracks, {Random? random}) {
  if (tracks.length <= 1) return List<Track>.unmodifiable(tracks);
  final shuffled = [...tracks]..shuffle(random ?? Random());
  return List<Track>.unmodifiable(shuffled);
}
