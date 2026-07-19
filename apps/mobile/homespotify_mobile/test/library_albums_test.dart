import 'package:flutter_test/flutter_test.dart';

import 'package:homespotify_mobile/src/features/library/domain/track.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_albums.dart';

void main() {
  const genesis = Track(
    id: 1,
    title: 'Genesis',
    artist: 'Justice',
    album: 'Cross',
    hasCover: false,
    durationSeconds: 200,
    extension: '.flac',
    mimeType: 'audio/flac',
  );
  const stress = Track(
    id: 2,
    title: 'Stress',
    artist: 'Justice',
    album: 'Cross',
    hasCover: true,
    durationSeconds: 260,
    extension: '.wav',
    mimeType: 'audio/wav',
  );
  const genesisLive = Track(
    id: 3,
    title: 'Genesis (Live)',
    artist: 'Justice & Friends',
    album: 'cross ', // casse/espaces différents : même album.
    hasCover: false,
    durationSeconds: 100,
    extension: '.flac',
    mimeType: 'audio/flac',
  );
  const aero = Track(
    id: 4,
    title: 'Aerodynamic',
    artist: 'Daft Punk',
    album: 'Discovery',
    hasCover: false,
    durationSeconds: 212,
    extension: '.wav',
    mimeType: 'audio/wav',
  );
  const zulu = Track(
    id: 5,
    title: 'Zulu',
    artist: 'Inconnu',
    album: '',
    hasCover: false,
  );

  test('groupement par album, clé stable insensible à la casse/espaces', () {
    final albums = groupTracksIntoAlbums(const [
      genesis,
      stress,
      genesisLive,
      aero,
    ]);

    expect(albums, hasLength(2));
    final cross = albums.firstWhere((a) => a.title == 'Cross');
    expect(cross.key, 'a:cross');
    expect(albumKeyForTrack(genesisLive), cross.key);
    expect(cross.trackCount, 3);
    final discovery = albums.firstWhere((a) => a.title == 'Discovery');
    expect(discovery.trackCount, 1);
  });

  test('album inconnu : pistes sans album regroupées, jamais de crash', () {
    final albums = groupTracksIntoAlbums(const [zulu, genesis]);

    final unknown = albums.firstWhere((a) => a.isUnknown);
    expect(unknown.title, unknownAlbumTitle);
    expect(unknown.key, unknownAlbumKey);
    expect(unknown.trackCount, 1);
    expect(unknown.totalDuration, Duration.zero);
  });

  test('durée totale et nombre de pistes', () {
    final albums = groupTracksIntoAlbums(const [genesis, stress]);

    expect(albums.single.trackCount, 2);
    expect(albums.single.totalDuration, const Duration(seconds: 460));
    expect(formatAlbumDuration(albums.single.totalDuration), '7 min');
    expect(formatAlbumDuration(const Duration(minutes: 72)), '1 h 12 min');
  });

  test('tri A → Z, « Album inconnu » en dernier', () {
    final albums = groupTracksIntoAlbums(const [zulu, genesis, aero]);

    expect(albums.map((a) => a.title).toList(), [
      'Cross',
      'Discovery',
      unknownAlbumTitle,
    ]);
  });

  test('artiste principal : le plus fréquent parmi les pistes', () {
    final albums = groupTracksIntoAlbums(const [genesis, stress, genesisLive]);

    expect(albums.single.artist, 'Justice');
  });

  test('pochette et format dominant', () {
    final albums = groupTracksIntoAlbums(const [genesis, stress, genesisLive]);

    // Première piste avec cover : Stress (id 2).
    expect(albums.single.coverTrackId, 2);
    // 2 FLAC vs 1 WAV → FLAC dominant.
    expect(albums.single.dominantFormat, 'FLAC');

    // Égalité 1-1 → pas de format dominant.
    final tie = groupTracksIntoAlbums(const [genesis, stress]);
    expect(tie.single.dominantFormat, isNull);
  });
}
