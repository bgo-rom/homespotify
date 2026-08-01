import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homespotify_mobile/src/features/home/application/home_sections.dart';
import 'package:homespotify_mobile/src/features/library/data/library_api.dart';
import 'package:homespotify_mobile/src/features/library/domain/track.dart';
import 'package:homespotify_mobile/src/features/listening/data/listening_activity_api.dart';
import 'package:homespotify_mobile/src/features/listening/domain/listening_activity.dart';

Track makeTrack(
  int id, {
  String title = 'Titre',
  String artist = 'Artiste',
  String album = 'Album',
}) {
  return Track(
    id: id,
    title: '$title $id',
    artist: artist,
    album: album,
    hasCover: false,
    durationSeconds: 200,
  );
}

ListeningSession makeSession(
  int trackId, {
  String artist = 'Artiste',
  bool qualified = true,
  DateTime? at,
}) {
  final moment = at ?? DateTime(2026, 7, 25, 12);
  return ListeningSession(
    id: trackId * 100,
    track: ListeningTrack(
      id: trackId,
      title: 'Titre $trackId',
      artist: artist,
      album: 'Album',
      durationMs: 200000,
      coverUrl: null,
      available: true,
    ),
    startedAt: moment,
    lastActivityAt: moment,
    listenedMs: qualified ? 120000 : 2000,
    positionMs: 0,
    durationMs: 200000,
    status: 'ENDED',
    endReason: 'COMPLETED',
    qualifiedPlay: qualified,
    completed: qualified,
  );
}

class FakeListeningActivityApi implements ListeningActivityApi {
  FakeListeningActivityApi(this.sessions);

  final List<ListeningSession> sessions;
  int activityCalls = 0;

  @override
  Future<ListeningActivityPage> fetchActivity({String? cursor}) async {
    activityCalls += 1;
    return ListeningActivityPage(items: sessions, nextCursor: null);
  }

  @override
  Future<void> sendBatch(List<Map<String, dynamic>> events) async {}

  @override
  Future<List<ResumeListeningItem>> fetchResume() async => const [];

  @override
  Future<void> clearActivity() async {}
}

ProviderContainer makeContainer({
  List<Track> library = const [],
  List<ListeningSession> sessions = const [],
}) {
  final container = ProviderContainer(
    overrides: [
      libraryProvider.overrideWith((ref) async => library),
      listeningActivityApiProvider.overrideWithValue(
        FakeListeningActivityApi(sessions),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('recentlyAddedTracksProvider', () {
    test('classe par identifiant décroissant et borne la liste', () async {
      final library = [for (var i = 1; i <= 20; i += 1) makeTrack(i)];
      final container = makeContainer(library: library);
      await container.read(libraryProvider.future);

      final recent = container.read(recentlyAddedTracksProvider);

      expect(recent, hasLength(kHomeSectionLimit));
      expect(recent.first.id, 20, reason: 'le plus grand id = le plus récent');
      expect(recent.last.id, 20 - kHomeSectionLimit + 1);
    });

    test('bibliothèque vide : section vide, aucun crash', () {
      final container = makeContainer();
      expect(container.read(recentlyAddedTracksProvider), isEmpty);
    });
  });

  group('recentAlbumsProvider', () {
    test('classe les albums par piste la plus récente', () async {
      final library = [
        makeTrack(1, album: 'Ancien'),
        makeTrack(2, album: 'Ancien'),
        makeTrack(50, album: 'Nouveau'),
        makeTrack(10, album: 'Milieu'),
      ];
      final container = makeContainer(library: library);
      await container.read(libraryProvider.future);

      final albums = container.read(recentAlbumsProvider);

      expect(albums.map((a) => a.title).take(3), [
        'Nouveau',
        'Milieu',
        'Ancien',
      ]);
    });
  });

  group('recentlyPlayedTracksProvider', () {
    test('dédoublonne et conserve l’ordre de l’historique', () async {
      final library = [makeTrack(1), makeTrack(2), makeTrack(3)];
      final container = makeContainer(
        library: library,
        sessions: [
          makeSession(3),
          makeSession(1),
          makeSession(3), // réécoute : ne doit pas réapparaître
          makeSession(2),
        ],
      );
      await container.read(libraryProvider.future);
      await container.read(listeningHistoryProvider.future);

      final played = container.read(recentlyPlayedTracksProvider);

      expect(played.map((t) => t.id), [3, 1, 2]);
    });

    test('ignore une piste absente de la bibliothèque', () async {
      final container = makeContainer(
        library: [makeTrack(1)],
        sessions: [makeSession(99), makeSession(1)],
      );
      await container.read(libraryProvider.future);
      await container.read(listeningHistoryProvider.future);

      final played = container.read(recentlyPlayedTracksProvider);

      expect(played.map((t) => t.id), [1]);
    });

    test('historique vide : section vide', () async {
      final container = makeContainer(library: [makeTrack(1)]);
      await container.read(libraryProvider.future);
      await container.read(listeningHistoryProvider.future);

      expect(container.read(recentlyPlayedTracksProvider), isEmpty);
    });
  });

  group('frequentArtistsProvider', () {
    test('classe par nombre d’écoutes qualifiées', () async {
      final library = [
        makeTrack(1, artist: 'Alpha'),
        makeTrack(2, artist: 'Beta'),
        makeTrack(3, artist: 'Gamma'),
      ];
      final container = makeContainer(
        library: library,
        sessions: [
          makeSession(2, artist: 'Beta'),
          makeSession(2, artist: 'Beta'),
          makeSession(2, artist: 'Beta'),
          makeSession(1, artist: 'Alpha'),
          makeSession(1, artist: 'Alpha'),
          makeSession(3, artist: 'Gamma'),
        ],
      );
      await container.read(libraryProvider.future);
      await container.read(listeningHistoryProvider.future);

      final artists = container.read(frequentArtistsProvider);

      expect(artists.map((a) => a.name), ['Beta', 'Alpha', 'Gamma']);
    });

    test('les écoutes non qualifiées ne comptent pas', () async {
      final library = [
        makeTrack(1, artist: 'Alpha'),
        makeTrack(2, artist: 'Beta'),
      ];
      final container = makeContainer(
        library: library,
        sessions: [
          // Beta a plus de sessions, mais aucune ne compte.
          makeSession(2, artist: 'Beta', qualified: false),
          makeSession(2, artist: 'Beta', qualified: false),
          makeSession(2, artist: 'Beta', qualified: false),
          makeSession(1, artist: 'Alpha'),
        ],
      );
      await container.read(libraryProvider.future);
      await container.read(listeningHistoryProvider.future);

      final artists = container.read(frequentArtistsProvider);

      expect(artists.map((a) => a.name), ['Alpha']);
    });

    test('un artiste absent de la bibliothèque est écarté', () async {
      final container = makeContainer(
        library: [makeTrack(1, artist: 'Alpha')],
        sessions: [
          makeSession(9, artist: 'Inconnu du disque'),
          makeSession(1, artist: 'Alpha'),
        ],
      );
      await container.read(libraryProvider.future);
      await container.read(listeningHistoryProvider.future);

      expect(container.read(frequentArtistsProvider).map((a) => a.name), [
        'Alpha',
      ]);
    });
  });

  group('listeningHistoryProvider', () {
    test('une seule requête sert toutes les sections dérivées', () async {
      final api = FakeListeningActivityApi([makeSession(1)]);
      final container = ProviderContainer(
        overrides: [
          libraryProvider.overrideWith((ref) async => [makeTrack(1)]),
          listeningActivityApiProvider.overrideWithValue(api),
        ],
      );
      addTearDown(container.dispose);

      await container.read(libraryProvider.future);
      await container.read(listeningHistoryProvider.future);
      container.read(recentlyPlayedTracksProvider);
      container.read(frequentArtistsProvider);

      expect(api.activityCalls, 1);
    });
  });

  group('shuffledLibraryQueue', () {
    test('conserve exactement les mêmes pistes', () {
      final library = [for (var i = 1; i <= 30; i += 1) makeTrack(i)];
      final queue = shuffledLibraryQueue(library, random: Random(42));

      expect(queue, hasLength(library.length));
      expect(queue.map((t) => t.id).toSet(), library.map((t) => t.id).toSet());
    });

    test('mélange réellement l’ordre', () {
      final library = [for (var i = 1; i <= 30; i += 1) makeTrack(i)];
      final queue = shuffledLibraryQueue(library, random: Random(42));

      expect(
        queue.map((t) => t.id).toList(),
        isNot(library.map((t) => t.id).toList()),
      );
    });

    test('liste vide ou unitaire : rien ne casse', () {
      expect(shuffledLibraryQueue(const []), isEmpty);
      expect(shuffledLibraryQueue([makeTrack(1)]).single.id, 1);
    });

    test('ne modifie pas la liste source', () {
      final library = [makeTrack(1), makeTrack(2), makeTrack(3)];
      final before = library.map((t) => t.id).toList();
      shuffledLibraryQueue(library, random: Random(7));
      expect(library.map((t) => t.id).toList(), before);
    });
  });
}
