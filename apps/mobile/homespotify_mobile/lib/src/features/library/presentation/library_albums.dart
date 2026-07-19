import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../data/library_api.dart';
import '../domain/track.dart';

/// Libellé affiché pour les pistes sans album.
const String unknownAlbumTitle = 'Album inconnu';

/// Clé réservée aux pistes sans album (préfixes distincts pour éviter toute
/// collision avec un vrai album qui s'appellerait « inconnu »).
const String unknownAlbumKey = 'u:';

/// Clé stable d'un album depuis son titre (insensible à la casse/espaces).
String albumKeyForTitle(String? albumTitle) {
  final normalized = (albumTitle ?? '').trim().toLowerCase();
  return normalized.isEmpty ? unknownAlbumKey : 'a:$normalized';
}

/// Clé stable d'un album pour une piste.
String albumKeyForTrack(Track track) => albumKeyForTitle(track.album);

/// Identifiant de route URL-safe d'un album : base64Url de la clé.
///
/// Aucun caractère réservé (alphabet A–Z a–z 0–9 `-` `_` `=`), donc jamais de
/// percent-encoding dans l'URI : les titres avec apostrophes, `%`, `/`,
/// accents ou symboles ne peuvent plus produire d'URI invalide (cf. L-018).
/// Le nom brut d'un album ne doit JAMAIS être mis directement dans une route.
String albumRouteId(String albumKey) => base64UrlEncode(utf8.encode(albumKey));

/// Clé d'album depuis un identifiant de route ; null si l'identifiant est
/// illisible (jamais d'exception, donc jamais d'écran rouge).
String? albumKeyFromRouteId(String routeId) {
  try {
    return utf8.decode(base64Url.decode(base64.normalize(routeId)));
  } on FormatException catch (error) {
    logError('identifiant de route album illisible: "$routeId"', error: error);
    return null;
  }
}

/// Vue agrégée d'un album, dérivée des pistes chargées.
class AlbumSummary {
  const AlbumSummary({
    required this.key,
    required this.title,
    required this.artist,
    required this.tracks,
    required this.totalDuration,
    this.coverTrackId,
    this.dominantFormat,
  });

  final String key;
  final String title;

  /// Artiste principal : le plus fréquent parmi les pistes de l'album.
  final String artist;

  /// Pistes de l'album, dans l'ordre de la bibliothèque.
  final List<Track> tracks;

  final Duration totalDuration;

  /// Piste dont la pochette représente l'album (première avec cover).
  final int? coverTrackId;

  /// 'FLAC' ou 'WAV' si un format domine strictement, sinon null.
  final String? dominantFormat;

  int get trackCount => tracks.length;

  bool get isUnknown => key == unknownAlbumKey;
}

/// Regroupe les pistes par album, trié par titre A → Z (« Album inconnu » en
/// fin de liste). Fonction pure, sans dépendance widget.
List<AlbumSummary> groupTracksIntoAlbums(List<Track> tracks) {
  final groups = <String, List<Track>>{};
  for (final track in tracks) {
    groups.putIfAbsent(albumKeyForTrack(track), () => <Track>[]).add(track);
  }

  final albums = groups.entries.map((entry) {
    final albumTracks = List<Track>.unmodifiable(entry.value);
    final isUnknown = entry.key == unknownAlbumKey;
    return AlbumSummary(
      key: entry.key,
      title: isUnknown ? unknownAlbumTitle : albumTracks.first.album.trim(),
      artist: _principalArtist(albumTracks),
      tracks: albumTracks,
      totalDuration: albumTracksDuration(albumTracks),
      coverTrackId: _coverTrackId(albumTracks),
      dominantFormat: _dominantFormat(albumTracks),
    );
  }).toList();

  albums.sort((a, b) {
    if (a.isUnknown != b.isUnknown) return a.isUnknown ? 1 : -1;
    return a.title.toLowerCase().compareTo(b.title.toLowerCase());
  });
  return albums;
}

/// Durée cumulée (les pistes sans durée comptent pour zéro).
Duration albumTracksDuration(List<Track> tracks) {
  var totalMs = 0;
  for (final track in tracks) {
    final seconds = track.durationSeconds;
    if (seconds != null) totalMs += (seconds * 1000).round();
  }
  return Duration(milliseconds: totalMs);
}

/// Format lisible d'une durée d'album : '42 min' ou '1 h 12 min'.
String formatAlbumDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes % 60;
  if (hours > 0) return '$hours h $minutes min';
  if (minutes > 0) return '$minutes min';
  return '${duration.inSeconds} s';
}

String _principalArtist(List<Track> tracks) {
  final counts = <String, int>{};
  for (final track in tracks) {
    counts.update(track.artist, (n) => n + 1, ifAbsent: () => 1);
  }
  String best = tracks.first.artist;
  var bestCount = 0;
  for (final track in tracks) {
    final count = counts[track.artist]!;
    if (count > bestCount) {
      best = track.artist;
      bestCount = count;
    }
  }
  return best;
}

int? _coverTrackId(List<Track> tracks) {
  for (final track in tracks) {
    if (track.hasCover) return track.id;
  }
  return null;
}

String? _dominantFormat(List<Track> tracks) {
  var flac = 0;
  var wav = 0;
  for (final track in tracks) {
    switch (track.formatLabel) {
      case 'FLAC':
        flac += 1;
      case 'WAV':
        wav += 1;
    }
  }
  if (flac == 0 && wav == 0) return null;
  if (flac == wav) return null;
  return flac > wav ? 'FLAC' : 'WAV';
}

/// Albums dérivés de toutes les pistes chargées (indépendant de la recherche
/// et du tri de la bibliothèque).
final albumsProvider = Provider<List<AlbumSummary>>((ref) {
  final tracks = ref.watch(libraryProvider).asData?.value ?? const <Track>[];
  return groupTracksIntoAlbums(tracks);
});
