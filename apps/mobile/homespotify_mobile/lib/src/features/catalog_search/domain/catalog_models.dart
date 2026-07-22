/// Modèles de la recherche catalogue (miroir du modèle unifié backend).
/// AUCUN secret fournisseur, aucun chemin physique : uniquement des
/// métadonnées publiques, des liens https validés côté serveur et des
/// descripteurs de preview éphémères.
library;

enum CatalogEntityType {
  track('track', 'Titres'),
  artist('artist', 'Artistes'),
  album('album', 'Albums'),
  playlist('playlist', 'Playlists');

  const CatalogEntityType(this.wireName, this.label);

  final String wireName;
  final String label;

  static CatalogEntityType fromWire(String? raw) => CatalogEntityType.values
      .firstWhere((value) => value.wireName == raw, orElse: () => track);
}

/// Statut de disponibilité par plateforme — JAMAIS un booléen : UNKNOWN
/// n'est pas « indisponible ».
enum PlatformAvailability {
  confirmed('CONFIRMED'),
  linkFound('LINK_FOUND'),
  searchLinkOnly('SEARCH_LINK_ONLY'),
  unavailableConfirmed('UNAVAILABLE_CONFIRMED'),
  unknown('UNKNOWN'),
  providerDisabled('PROVIDER_DISABLED'),
  providerError('PROVIDER_ERROR');

  const PlatformAvailability(this.wireName);

  final String wireName;

  static PlatformAvailability fromWire(String? raw) =>
      PlatformAvailability.values.firstWhere(
        (value) => value.wireName == raw,
        orElse: () => PlatformAvailability.unknown,
      );

  /// Une correspondance vérifiée existe (badge plateforme affichable).
  bool get isPositive => this == confirmed || this == linkFound;
}

class CatalogEntityRef {
  const CatalogEntityRef({
    required this.provider,
    required this.entityType,
    required this.externalId,
    this.externalUrl,
  });

  final String provider;
  final CatalogEntityType entityType;
  final String externalId;
  final String? externalUrl;

  /// Égalité par valeur : requis pour servir de clé de provider family
  /// (sinon chaque rebuild relancerait la requête).
  @override
  bool operator ==(Object other) =>
      other is CatalogEntityRef &&
      other.provider == provider &&
      other.entityType == entityType &&
      other.externalId == externalId;

  @override
  int get hashCode => Object.hash(provider, entityType, externalId);

  static CatalogEntityRef? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final provider = json['provider'] as String?;
    final externalId = json['externalId'] as String?;
    if (provider == null || externalId == null || externalId.isEmpty) {
      return null;
    }
    return CatalogEntityRef(
      provider: provider,
      entityType: CatalogEntityType.fromWire(json['entityType'] as String?),
      externalId: externalId,
      externalUrl: json['externalUrl'] as String?,
    );
  }
}

class PlatformLink {
  const PlatformLink({required this.platform, required this.status, this.url});

  final String platform;
  final PlatformAvailability status;
  final String? url;

  static PlatformLink fromJson(Map<String, dynamic> json) => PlatformLink(
    platform: json['platform'] as String? ?? '',
    status: PlatformAvailability.fromWire(json['status'] as String?),
    url: (json['url'] as String?)?.isEmpty ?? true
        ? null
        : json['url'] as String,
  );
}

/// Preview officielle éphémère : lue en streaming uniquement, jamais
/// téléchargée ni mise hors ligne, jamais ajoutée à l'historique d'écoute.
class CatalogPreview {
  const CatalogPreview({
    required this.provider,
    required this.url,
    this.durationMs,
    this.requiresOfficialSdk = false,
    this.attribution,
  });

  final String provider;
  final String url;
  final int? durationMs;
  final bool requiresOfficialSdk;
  final String? attribution;

  static CatalogPreview? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final url = json['url'] as String?;
    if (url == null || !url.startsWith('https://')) return null;
    return CatalogPreview(
      provider: json['provider'] as String? ?? '',
      url: url,
      durationMs: (json['durationMs'] as num?)?.toInt(),
      requiresOfficialSdk: json['requiresOfficialSdk'] as bool? ?? false,
      attribution: json['attribution'] as String?,
    );
  }
}

class CatalogResult {
  const CatalogResult({
    required this.canonicalKey,
    required this.entityType,
    required this.title,
    required this.artistNames,
    this.album,
    this.durationMs,
    this.releaseDate,
    this.explicit,
    this.imageUrl,
    this.isrc,
    this.mbid,
    this.trackCount,
    this.references = const [],
    this.links = const [],
    this.preview,
  });

  final String canonicalKey;
  final CatalogEntityType entityType;
  final String title;
  final List<String> artistNames;
  final String? album;
  final int? durationMs;
  final String? releaseDate;
  final bool? explicit;
  final String? imageUrl;
  final String? isrc;
  final String? mbid;
  final int? trackCount;
  final List<CatalogEntityRef> references;
  final List<PlatformLink> links;
  final CatalogPreview? preview;

  String get artistLabel => artistNames.join(', ');

  /// Référence pour ouvrir une fiche (première disponible).
  CatalogEntityRef? get primaryReference =>
      references.isEmpty ? null : references.first;

  /// Référence de l'artiste principal (fiche artiste), si connue.
  List<PlatformLink> get positiveLinks =>
      links.where((link) => link.status.isPositive).toList(growable: false);

  static CatalogResult fromJson(Map<String, dynamic> json) {
    final artists = (json['artists'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((artist) => artist['name'] as String? ?? '')
        .where((name) => name.isNotEmpty)
        .toList(growable: false);
    final images = (json['images'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((image) => image['url'] as String? ?? '')
        .where((url) => url.startsWith('https://'))
        .toList(growable: false);
    return CatalogResult(
      canonicalKey: json['canonicalKey'] as String? ?? '',
      entityType: CatalogEntityType.fromWire(json['entityType'] as String?),
      title: json['title'] as String? ?? '',
      artistNames: artists,
      album: json['album'] as String?,
      durationMs: (json['durationMs'] as num?)?.toInt(),
      releaseDate: json['releaseDate'] as String?,
      explicit: json['explicit'] as bool?,
      imageUrl: images.isEmpty ? null : images.first,
      isrc: json['isrc'] as String?,
      mbid: json['mbid'] as String?,
      trackCount: (json['trackCount'] as num?)?.toInt(),
      references: (json['providerReferences'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(CatalogEntityRef.fromJson)
          .whereType<CatalogEntityRef>()
          .toList(growable: false),
      links: (json['externalLinks'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(PlatformLink.fromJson)
          .toList(growable: false),
      preview: CatalogPreview.fromJson(
        json['preview'] as Map<String, dynamic>?,
      ),
    );
  }
}

class ProviderStatus {
  const ProviderStatus({required this.id, required this.status, this.message});

  final String id;

  /// OK | DEGRADED | DISABLED.
  final String status;
  final String? message;

  static ProviderStatus fromJson(Map<String, dynamic> json) => ProviderStatus(
    id: json['id'] as String? ?? '',
    status: json['status'] as String? ?? 'DISABLED',
    message: json['message'] as String?,
  );
}

class CatalogSearchPage {
  const CatalogSearchPage({
    required this.items,
    this.nextCursor,
    this.providers = const [],
  });

  final List<CatalogResult> items;
  final String? nextCursor;
  final List<ProviderStatus> providers;

  bool get hasDegradedProvider =>
      providers.any((provider) => provider.status == 'DEGRADED');

  static CatalogSearchPage fromJson(Map<String, dynamic> json) =>
      CatalogSearchPage(
        items: (json['items'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(CatalogResult.fromJson)
            .toList(growable: false),
        nextCursor: json['nextCursor'] as String?,
        providers: (json['providers'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ProviderStatus.fromJson)
            .toList(growable: false),
      );
}

class CatalogAlbumTrack {
  const CatalogAlbumTrack({
    required this.position,
    required this.title,
    this.discNumber,
    this.trackNumber,
    this.artistNames = const [],
    this.durationMs,
    this.explicit,
    this.isrc,
    this.preview,
  });

  final int position;
  final String title;
  final int? discNumber;
  final int? trackNumber;
  final List<String> artistNames;
  final int? durationMs;
  final bool? explicit;
  final String? isrc;
  final CatalogPreview? preview;

  static CatalogAlbumTrack fromJson(Map<String, dynamic> json) =>
      CatalogAlbumTrack(
        position: (json['position'] as num?)?.toInt() ?? 0,
        title: json['title'] as String? ?? '',
        discNumber: (json['discNumber'] as num?)?.toInt(),
        trackNumber: (json['trackNumber'] as num?)?.toInt(),
        artistNames: (json['artists'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map((artist) => artist['name'] as String? ?? '')
            .where((name) => name.isNotEmpty)
            .toList(growable: false),
        durationMs: (json['durationMs'] as num?)?.toInt(),
        explicit: json['explicit'] as bool?,
        isrc: json['isrc'] as String?,
        preview: CatalogPreview.fromJson(
          json['preview'] as Map<String, dynamic>?,
        ),
      );
}

class CatalogAlbumDetail {
  const CatalogAlbumDetail({
    required this.title,
    required this.artistNames,
    this.releaseDate,
    this.albumType,
    this.label,
    this.imageUrl,
    this.discCount,
    this.trackCount,
    this.tracks = const [],
    this.links = const [],
    this.reference,
  });

  final String title;
  final List<String> artistNames;
  final String? releaseDate;
  final String? albumType;
  final String? label;
  final String? imageUrl;
  final int? discCount;
  final int? trackCount;
  final List<CatalogAlbumTrack> tracks;
  final List<PlatformLink> links;
  final CatalogEntityRef? reference;

  int get totalDurationMs =>
      tracks.fold(0, (sum, track) => sum + (track.durationMs ?? 0));

  static CatalogAlbumDetail fromJson(Map<String, dynamic> json) {
    final images = (json['images'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((image) => image['url'] as String? ?? '')
        .where((url) => url.startsWith('https://'))
        .toList(growable: false);
    return CatalogAlbumDetail(
      title: json['title'] as String? ?? '',
      artistNames: (json['artists'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map((artist) => artist['name'] as String? ?? '')
          .where((name) => name.isNotEmpty)
          .toList(growable: false),
      releaseDate: json['releaseDate'] as String?,
      albumType: json['albumType'] as String?,
      label: json['label'] as String?,
      imageUrl: images.isEmpty ? null : images.first,
      discCount: (json['discCount'] as num?)?.toInt(),
      trackCount: (json['trackCount'] as num?)?.toInt(),
      tracks: (json['tracks'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(CatalogAlbumTrack.fromJson)
          .toList(growable: false),
      links: (json['externalLinks'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(PlatformLink.fromJson)
          .toList(growable: false),
      reference: CatalogEntityRef.fromJson(
        json['reference'] as Map<String, dynamic>?,
      ),
    );
  }
}

class CatalogAlbumSummary {
  const CatalogAlbumSummary({
    required this.title,
    this.albumType,
    this.releaseDate,
    this.trackCount,
    this.imageUrl,
    this.reference,
  });

  final String title;
  final String? albumType;
  final String? releaseDate;
  final int? trackCount;
  final String? imageUrl;
  final CatalogEntityRef? reference;

  static CatalogAlbumSummary fromJson(Map<String, dynamic> json) {
    final images = (json['images'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((image) => image['url'] as String? ?? '')
        .where((url) => url.startsWith('https://'))
        .toList(growable: false);
    return CatalogAlbumSummary(
      title: json['title'] as String? ?? '',
      albumType: json['albumType'] as String?,
      releaseDate: json['releaseDate'] as String?,
      trackCount: (json['trackCount'] as num?)?.toInt(),
      imageUrl: images.isEmpty ? null : images.first,
      reference: CatalogEntityRef.fromJson(
        json['reference'] as Map<String, dynamic>?,
      ),
    );
  }
}

class CatalogArtistDetail {
  const CatalogArtistDetail({
    required this.name,
    this.disambiguation,
    this.imageUrl,
    this.genres = const [],
    this.links = const [],
    this.reference,
  });

  final String name;
  final String? disambiguation;
  final String? imageUrl;
  final List<String> genres;
  final List<PlatformLink> links;
  final CatalogEntityRef? reference;

  static CatalogArtistDetail fromJson(Map<String, dynamic> json) {
    final images = (json['images'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((image) => image['url'] as String? ?? '')
        .where((url) => url.startsWith('https://'))
        .toList(growable: false);
    return CatalogArtistDetail(
      name: json['name'] as String? ?? '',
      disambiguation: json['disambiguation'] as String?,
      imageUrl: images.isEmpty ? null : images.first,
      genres: (json['genres'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(growable: false),
      links: (json['externalLinks'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(PlatformLink.fromJson)
          .toList(growable: false),
      reference: CatalogEntityRef.fromJson(
        json['reference'] as Map<String, dynamic>?,
      ),
    );
  }
}

class CatalogAlbumPage {
  const CatalogAlbumPage({required this.items, this.nextCursor});

  final List<CatalogAlbumSummary> items;
  final String? nextCursor;

  static CatalogAlbumPage fromJson(Map<String, dynamic> json) =>
      CatalogAlbumPage(
        items: (json['items'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(CatalogAlbumSummary.fromJson)
            .toList(growable: false),
        nextCursor: json['nextCursor'] as String?,
      );
}
