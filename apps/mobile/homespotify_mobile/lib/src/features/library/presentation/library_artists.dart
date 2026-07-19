import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../data/library_api.dart';
import '../domain/track.dart';
import 'library_albums.dart';

/// Libelle affiche pour les pistes sans artiste exploitable.
const String unknownArtistTitle = 'Artiste inconnu';

/// Cle reservee aux metadonnees artiste absentes.
const String unknownArtistKey = 'u:';

/// Nom d'artiste nettoye pour l'affichage et le groupement.
String artistDisplayName(String? artistName) {
  final trimmed = (artistName ?? '').trim();
  if (trimmed.isEmpty ||
      trimmed.toLowerCase() == unknownArtistTitle.toLowerCase()) {
    return unknownArtistTitle;
  }
  return trimmed;
}

/// Cle stable d'un artiste, insensible a la casse et aux espaces externes.
String artistKeyForName(String? artistName) {
  final displayName = artistDisplayName(artistName);
  return displayName == unknownArtistTitle
      ? unknownArtistKey
      : 'a:${displayName.toLowerCase()}';
}

String artistKeyForTrack(Track track) => artistKeyForName(track.artist);

/// Identifiant URL-safe, construit sans texte libre dans la route.
String artistRouteId(String artistKey) =>
    base64UrlEncode(utf8.encode(artistKey));

/// Decode une cle artiste sans jamais propager une exception vers l'UI.
String? artistKeyFromRouteId(String routeId) {
  try {
    return utf8.decode(base64Url.decode(base64.normalize(routeId)));
  } on FormatException catch (error) {
    logError(
      'identifiant de route artiste illisible: "$routeId"',
      error: error,
    );
    return null;
  }
}

/// Vue agregee d'un artiste, derivee de la bibliotheque deja chargee.
class ArtistSummary {
  const ArtistSummary({
    required this.key,
    required this.name,
    required this.tracks,
    required this.albums,
    required this.totalDuration,
    this.coverTrackId,
  });

  final String key;
  final String name;
  final List<Track> tracks;
  final List<AlbumSummary> albums;
  final Duration totalDuration;

  /// Premiere piste de l'artiste possedant une pochette.
  final int? coverTrackId;

  int get trackCount => tracks.length;
  int get albumCount => albums.length;
  bool get isUnknown => key == unknownArtistKey;
}

/// Regroupe les pistes par artiste et trie A-Z, artiste inconnu en dernier.
List<ArtistSummary> groupTracksIntoArtists(List<Track> tracks) {
  final groups = <String, List<Track>>{};
  for (final track in tracks) {
    groups.putIfAbsent(artistKeyForTrack(track), () => <Track>[]).add(track);
  }

  final artists = groups.entries.map((entry) {
    final artistTracks = List<Track>.unmodifiable(entry.value);
    final isUnknown = entry.key == unknownArtistKey;
    return ArtistSummary(
      key: entry.key,
      name: isUnknown
          ? unknownArtistTitle
          : artistDisplayName(artistTracks.first.artist),
      tracks: artistTracks,
      albums: List<AlbumSummary>.unmodifiable(
        groupTracksIntoAlbums(artistTracks),
      ),
      totalDuration: artistTracksDuration(artistTracks),
      coverTrackId: _coverTrackId(artistTracks),
    );
  }).toList();

  artists.sort((a, b) {
    if (a.isUnknown != b.isUnknown) return a.isUnknown ? 1 : -1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return artists;
}

/// Duree cumulee ; une duree absente compte pour zero.
Duration artistTracksDuration(List<Track> tracks) {
  var totalMilliseconds = 0;
  for (final track in tracks) {
    final seconds = track.durationSeconds;
    if (seconds != null) {
      totalMilliseconds += (seconds * 1000).round();
    }
  }
  return Duration(milliseconds: totalMilliseconds);
}

String formatArtistDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes % 60;
  if (hours > 0) return '$hours h $minutes min';
  if (minutes > 0) return '$minutes min';
  return '${duration.inSeconds} s';
}

int? _coverTrackId(List<Track> tracks) {
  for (final track in tracks) {
    if (track.hasCover) return track.id;
  }
  return null;
}

/// Artistes derives de toutes les pistes chargees.
final artistsProvider = Provider<List<ArtistSummary>>((ref) {
  final tracks = ref.watch(libraryProvider).asData?.value ?? const <Track>[];
  return groupTracksIntoArtists(tracks);
});
