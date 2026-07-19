/// Qualité audio mesurée côté serveur (jamais déduite de l'extension).
class TrackQuality {
  const TrackQuality({
    required this.sampleRate,
    required this.bitDepth,
    required this.status,
    this.channels,
    this.bitrate,
  });

  final int sampleRate;
  final int bitDepth;
  final String status;
  final int? channels;
  final int? bitrate;

  factory TrackQuality.fromJson(Map<String, dynamic> json) {
    return TrackQuality(
      sampleRate: (json['sampleRate'] as num?)?.toInt() ?? 0,
      bitDepth: (json['bitDepth'] as num?)?.toInt() ?? 0,
      status: (json['status'] as String?) ?? 'inconnue',
      channels: (json['channels'] as num?)?.toInt(),
      bitrate: (json['bitrate'] as num?)?.toInt(),
    );
  }

  /// Libellé court pour l'UI, ex. "44.1kHz · 16bit". Null si specs inconnues.
  String? get shortLabel {
    if (sampleRate <= 0 || bitDepth <= 0) return null;
    final khz = (sampleRate / 1000).toStringAsFixed(
      sampleRate % 1000 == 0 ? 0 : 1,
    );
    return '${khz}kHz · ${bitDepth}bit';
  }
}

/// Piste de la bibliothèque, telle que renvoyée par `GET /api/tracks`.
class Track {
  const Track({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.hasCover,
    this.year,
    this.genre,
    this.durationSeconds,
    this.quality,
    this.mimeType,
    this.extension,
    this.sizeBytes,
    this.etag,
  });

  final int id;
  final String title;
  final String artist;
  final String album;
  final bool hasCover;
  final int? year;
  final String? genre;
  final double? durationSeconds;
  final TrackQuality? quality;
  final String? mimeType; // audio/wav | audio/flac
  final String? extension; // .wav | .flac
  final int? sizeBytes;
  final String? etag;

  factory Track.fromJson(Map<String, dynamic> json) {
    final rawTitle = (json['title'] as String?)?.trim();
    final rawArtist = (json['artist'] as String?)?.trim();
    final rawAlbum = (json['album'] as String?)?.trim();
    final quality = json['quality'];
    return Track(
      id: (json['id'] as num).toInt(),
      title: rawTitle == null || rawTitle.isEmpty ? 'Sans titre' : rawTitle,
      artist: rawArtist == null || rawArtist.isEmpty
          ? 'Artiste inconnu'
          : rawArtist,
      album: rawAlbum ?? '',
      hasCover: json['hasCover'] as bool? ?? false,
      year: (json['year'] as num?)?.toInt(),
      genre: json['genre'] as String?,
      durationSeconds: (json['durationSeconds'] as num?)?.toDouble(),
      quality: quality is Map<String, dynamic>
          ? TrackQuality.fromJson(quality)
          : null,
      mimeType: json['mimeType'] as String?,
      extension: json['extension'] as String?,
      sizeBytes: (json['sizeBytes'] as num?)?.toInt(),
      etag: (json['etag'] as String?)?.trim(),
    );
  }

  Duration? get duration => durationSeconds == null
      ? null
      : Duration(milliseconds: (durationSeconds! * 1000).round());

  /// Étiquette de format lisible : 'FLAC' ou 'WAV' (null si inconnu).
  String? get formatLabel {
    final ext = extension?.toLowerCase();
    if (ext == '.flac' || mimeType == 'audio/flac') return 'FLAC';
    if (ext == '.wav' || mimeType == 'audio/wav') return 'WAV';
    return null;
  }
}
