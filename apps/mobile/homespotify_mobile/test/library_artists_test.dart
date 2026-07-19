import 'package:flutter_test/flutter_test.dart';

import 'package:homespotify_mobile/src/features/library/domain/track.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_artists.dart';

void main() {
  const genesis = Track(
    id: 1,
    title: 'Genesis',
    artist: 'Justice',
    album: 'Cross',
    hasCover: false,
    durationSeconds: 200,
  );
  const stress = Track(
    id: 2,
    title: 'Stress',
    artist: ' justice ',
    album: 'Cross',
    hasCover: true,
    durationSeconds: 260,
  );
  const live = Track(
    id: 3,
    title: 'Genesis Live',
    artist: 'JUSTICE',
    album: 'Access All Arenas',
    hasCover: false,
    durationSeconds: 300,
  );
  const aero = Track(
    id: 4,
    title: 'Aerodynamic',
    artist: 'Daft Punk',
    album: 'Discovery',
    hasCover: false,
    durationSeconds: 212,
  );
  const missingArtist = Track(
    id: 5,
    title: 'Sans metadata',
    artist: '',
    album: '',
    hasCover: false,
  );
  const fallbackArtist = Track(
    id: 6,
    title: 'Fallback',
    artist: 'Artiste inconnu',
    album: '',
    hasCover: false,
  );

  test('groupe un artiste avec une clé stable casse/espaces', () {
    final artists = groupTracksIntoArtists(const [genesis, stress, live]);

    expect(artists, hasLength(1));
    expect(artists.single.key, 'a:justice');
    expect(artistKeyForTrack(stress), artists.single.key);
    expect(artistKeyForTrack(live), artists.single.key);
    expect(artists.single.trackCount, 3);
  });

  test('regroupe toutes les metadata absentes dans Artiste inconnu', () {
    final artists = groupTracksIntoArtists(const [
      missingArtist,
      fallbackArtist,
      genesis,
    ]);

    final unknown = artists.firstWhere((artist) => artist.isUnknown);
    expect(unknown.key, unknownArtistKey);
    expect(unknown.name, unknownArtistTitle);
    expect(unknown.trackCount, 2);
    expect(unknown.totalDuration, Duration.zero);
  });

  test('calcule durée, nombre de pistes et nombre d’albums', () {
    final artist = groupTracksIntoArtists(const [genesis, stress, live]).single;

    expect(artist.trackCount, 3);
    expect(artist.albumCount, 2);
    expect(artist.totalDuration, const Duration(seconds: 760));
    expect(formatArtistDuration(artist.totalDuration), '12 min');
    expect(formatArtistDuration(const Duration(minutes: 72)), '1 h 12 min');
  });

  test('trie les artistes A-Z avec Artiste inconnu en dernier', () {
    final artists = groupTracksIntoArtists(const [
      missingArtist,
      genesis,
      aero,
    ]);

    expect(artists.map((artist) => artist.name).toList(), [
      'Daft Punk',
      'Justice',
      unknownArtistTitle,
    ]);
  });

  test('sélectionne la première pochette représentative', () {
    final artist = groupTracksIntoArtists(const [genesis, stress, live]).single;

    expect(artist.coverTrackId, 2);
  });
}
