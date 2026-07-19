import 'package:flutter_test/flutter_test.dart';

import 'package:homespotify_mobile/src/features/library/domain/track.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_filters.dart';

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
  const aero = Track(
    id: 2,
    title: 'Aerodynamic',
    artist: 'Daft Punk',
    album: 'Discovery',
    hasCover: false,
    durationSeconds: 212,
    extension: '.wav',
    mimeType: 'audio/wav',
  );
  const breathe = Track(
    id: 3,
    title: 'Breathe',
    artist: 'Pink Floyd',
    album: 'The Dark Side of the Moon',
    hasCover: false,
    durationSeconds: 169,
    extension: '.flac',
    mimeType: 'audio/flac',
  );
  const sansDuree = Track(
    id: 4,
    title: 'Zulu',
    artist: 'Inconnu',
    album: '',
    hasCover: false,
  );
  const all = <Track>[genesis, aero, breathe, sansDuree];

  List<String> titles(List<Track> tracks) =>
      tracks.map((t) => t.title).toList();

  test('recherche vide : tout, trié par titre', () {
    final result = applyLibraryFilters(
      all,
      query: '',
      sort: LibrarySort.titleAsc,
    );
    expect(titles(result), ['Aerodynamic', 'Breathe', 'Genesis', 'Zulu']);
  });

  test('recherche par titre, insensible à la casse', () {
    final result = applyLibraryFilters(
      all,
      query: 'GENE',
      sort: LibrarySort.titleAsc,
    );
    expect(titles(result), ['Genesis']);
  });

  test('recherche par artiste', () {
    final result = applyLibraryFilters(
      all,
      query: 'daft',
      sort: LibrarySort.titleAsc,
    );
    expect(titles(result), ['Aerodynamic']);
  });

  test('recherche par album', () {
    final result = applyLibraryFilters(
      all,
      query: 'dark side',
      sort: LibrarySort.titleAsc,
    );
    expect(titles(result), ['Breathe']);
  });

  test('recherche sans résultat', () {
    final result = applyLibraryFilters(
      all,
      query: 'zzzz',
      sort: LibrarySort.titleAsc,
    );
    expect(result, isEmpty);
  });

  test('tri par artiste : artiste, puis album, puis titre', () {
    final result = applyLibraryFilters(
      all,
      query: '',
      sort: LibrarySort.artistAsc,
    );
    expect(titles(result), ['Aerodynamic', 'Zulu', 'Genesis', 'Breathe']);
  });

  test('tri par album', () {
    final result = applyLibraryFilters(
      all,
      query: '',
      sort: LibrarySort.albumAsc,
    );
    // Album vide en tête (ordre lexical), puis Cross, Discovery, The Dark…
    expect(titles(result), ['Zulu', 'Genesis', 'Aerodynamic', 'Breathe']);
  });

  test('tri par durée croissante, sans durée en fin', () {
    final result = applyLibraryFilters(
      all,
      query: '',
      sort: LibrarySort.duration,
    );
    expect(titles(result), ['Breathe', 'Genesis', 'Aerodynamic', 'Zulu']);
  });

  test('tri par format : FLAC, puis WAV, puis inconnu', () {
    final result = applyLibraryFilters(
      all,
      query: '',
      sort: LibrarySort.format,
    );
    expect(titles(result), ['Breathe', 'Genesis', 'Aerodynamic', 'Zulu']);
  });
}
