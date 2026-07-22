import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../offline/application/offline_index.dart';
import '../data/library_api.dart';
import '../domain/track.dart';

/// Ordres de tri de la bibliothèque.
enum LibrarySort {
  titleAsc('Titre (A → Z)'),
  artistAsc('Artiste (A → Z)'),
  albumAsc('Album (A → Z)'),
  duration('Durée'),
  format('Format (FLAC d’abord)');

  const LibrarySort(this.label);
  final String label;
}

/// Texte de recherche courant (vide = pas de filtre).
class LibrarySearchQuery extends Notifier<String> {
  @override
  String build() => '';

  void set(String value) => state = value;

  void clear() => state = '';
}

final librarySearchQueryProvider = NotifierProvider<LibrarySearchQuery, String>(
  LibrarySearchQuery.new,
  name: 'librarySearchQuery',
);

class LibrarySearchVisible extends Notifier<bool> {
  @override
  bool build() => false;

  void show() => state = true;

  void hide() => state = false;

  void toggle() => state = !state;
}

final librarySearchVisibleProvider =
    NotifierProvider<LibrarySearchVisible, bool>(LibrarySearchVisible.new);

/// Tri choisi ; vit à la racine du ProviderScope, donc conservé pour toute la
/// session (retours d'écran compris) sans stockage permanent.
class LibrarySortSetting extends Notifier<LibrarySort> {
  @override
  LibrarySort build() => LibrarySort.titleAsc;

  void set(LibrarySort value) => state = value;
}

final librarySortProvider = NotifierProvider<LibrarySortSetting, LibrarySort>(
  LibrarySortSetting.new,
  name: 'librarySort',
);

/// Filtre « Téléchargées » : ne montre que les pistes disponibles hors ligne.
class LibraryDownloadedOnly extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;

  void set(bool value) => state = value;
}

final libraryDownloadedOnlyProvider =
    NotifierProvider<LibraryDownloadedOnly, bool>(
      LibraryDownloadedOnly.new,
      name: 'libraryDownloadedOnly',
    );

/// Pistes visibles : bibliothèque chargée + recherche + tri.
///
/// Dérivé pur : seul ce provider (et les widgets qui l'écoutent) se recalcule
/// quand la recherche ou le tri change — pas l'AppBar ni le mini-player.
final mergedLibraryTracksProvider = Provider<List<Track>>((ref) {
  final remoteTracks =
      ref.watch(libraryProvider).asData?.value ?? const <Track>[];
  final localTracks = ref.watch(offlineLibraryTracksProvider);
  final byId = <int, Track>{for (final track in localTracks) track.id: track};
  // Les métadonnées serveur, plus riches, gagnent lorsqu'elles sont
  // disponibles ; le manifeste complète la liste en mode hors connexion.
  for (final track in remoteTracks) {
    byId[track.id] = track;
  }
  return byId.values.toList(growable: false);
});

final visibleTracksProvider = Provider<List<Track>>((ref) {
  final tracks = ref.watch(mergedLibraryTracksProvider);
  final query = ref.watch(librarySearchQueryProvider);
  final sort = ref.watch(librarySortProvider);
  final downloadedOnly = ref.watch(libraryDownloadedOnlyProvider);
  // Index hors ligne chargé UNE fois (jamais une requête SQLite par piste).
  final downloadedIds = ref.watch(offlineAvailableTrackIdsProvider);
  final result = applyLibraryFilters(
    tracks,
    query: query,
    sort: sort,
    onlyDownloaded: downloadedOnly,
    downloadedIds: downloadedIds,
  );
  logLibrary(
    'bibliothèque: ${tracks.length} pistes chargées, query="$query", '
    'tri=${sort.name}, téléchargées=${downloadedOnly ? 'seules' : 'toutes'}, '
    'visibles=${result.length}',
  );
  return result;
});

/// Filtre (titre/artiste/album, insensible à la casse, option « téléchargées
/// seulement ») puis trie. Fonction pure, testable sans widget.
List<Track> applyLibraryFilters(
  List<Track> tracks, {
  required String query,
  required LibrarySort sort,
  bool onlyDownloaded = false,
  Set<int> downloadedIds = const {},
}) {
  final q = query.trim().toLowerCase();
  final result = tracks
      .where((t) => !onlyDownloaded || downloadedIds.contains(t.id))
      .where(
        (t) =>
            q.isEmpty ||
            t.title.toLowerCase().contains(q) ||
            t.artist.toLowerCase().contains(q) ||
            t.album.toLowerCase().contains(q),
      )
      .toList();

  int text(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());
  int byTitle(Track a, Track b) => text(a.title, b.title);

  switch (sort) {
    case LibrarySort.titleAsc:
      result.sort(byTitle);
    case LibrarySort.artistAsc:
      result.sort((a, b) {
        final c = text(a.artist, b.artist);
        if (c != 0) return c;
        final d = text(a.album, b.album);
        return d != 0 ? d : byTitle(a, b);
      });
    case LibrarySort.albumAsc:
      result.sort((a, b) {
        final c = text(a.album, b.album);
        return c != 0 ? c : byTitle(a, b);
      });
    case LibrarySort.duration:
      result.sort((a, b) {
        // Durée croissante, pistes sans durée en fin de liste.
        final da = a.durationSeconds;
        final db = b.durationSeconds;
        if (da == null && db == null) return byTitle(a, b);
        if (da == null) return 1;
        if (db == null) return -1;
        final c = da.compareTo(db);
        return c != 0 ? c : byTitle(a, b);
      });
    case LibrarySort.format:
      result.sort((a, b) {
        // FLAC avant WAV, formats inconnus en fin de liste.
        int rank(Track t) => switch (t.formatLabel) {
          'FLAC' => 0,
          'WAV' => 1,
          _ => 2,
        };
        final c = rank(a).compareTo(rank(b));
        return c != 0 ? c : byTitle(a, b);
      });
  }
  return result;
}
