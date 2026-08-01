/// Modèles de la recherche catalogue (miroir du modèle unifié backend).
/// AUCUN secret fournisseur, aucun chemin physique : uniquement des
/// métadonnées publiques, des liens https validés côté serveur et des
/// descripteurs de preview éphémères.
library;

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

/// Garde AU PLUS UN lien positif par plateforme.
///
/// Le backend peut renvoyer plusieurs liens pour un même fournisseur (par
/// exemple un `CONFIRMED` et un `LINK_FOUND` issus de deux sources). Les écrans
/// keyent leurs badges et puces par nom de plateforme : sans cette
/// déduplication, deux widgets frères portent la même clé et Flutter fait
/// tomber tout l'écran avec « Duplicate keys found ».
///
/// `CONFIRMED` l'emporte sur `LINK_FOUND` ; à statut égal, le premier lien reçu
/// est conservé. [requireUrl] sert aux écrans qui n'affichent que des liens
/// ouvrables.
List<PlatformLink> dedupePositiveLinks(
  List<PlatformLink> links, {
  bool requireUrl = false,
}) {
  final best = <String, PlatformLink>{};
  for (final link in links) {
    if (!link.status.isPositive) continue;
    if (requireUrl && link.url == null) continue;
    final current = best[link.platform];
    if (current == null ||
        (current.status != PlatformAvailability.confirmed &&
            link.status == PlatformAvailability.confirmed)) {
      best[link.platform] = link;
    }
  }
  return List<PlatformLink>.unmodifiable(best.values);
}

class CatalogEntityRef {
  const CatalogEntityRef({
    required this.provider,
    required this.externalId,
    this.externalUrl,
  });

  final String provider;
  final String externalId;
  final String? externalUrl;

  /// Égalité par valeur : requis pour servir de clé de provider family
  /// (sinon chaque rebuild relancerait la requête).
  @override
  bool operator ==(Object other) =>
      other is CatalogEntityRef &&
      other.provider == provider &&
      other.externalId == externalId;

  @override
  int get hashCode => Object.hash(provider, externalId);

  static CatalogEntityRef? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final provider = json['provider'] as String?;
    final externalId = json['externalId'] as String?;
    if (provider == null || externalId == null || externalId.isEmpty) {
      return null;
    }
    return CatalogEntityRef(
      provider: provider,
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
    required this.title,
    required this.artistNames,
    this.album,
    this.durationMs,
    this.releaseDate,
    this.explicit,
    this.imageUrl,
    this.isrc,
    this.mbid,
    this.references = const [],
    this.links = const [],
    this.preview,
  });

  final String canonicalKey;
  final String title;
  final List<String> artistNames;
  final String? album;
  final int? durationMs;
  final String? releaseDate;
  final bool? explicit;
  final String? imageUrl;
  final String? isrc;
  final String? mbid;
  final List<CatalogEntityRef> references;
  final List<PlatformLink> links;
  final CatalogPreview? preview;

  String get artistLabel => artistNames.join(', ');

  /// Plateformes où une correspondance vérifiée existe, **une seule fois
  /// chacune**.
  ///
  /// Le backend peut renvoyer plusieurs liens pour un même fournisseur (par
  /// exemple un `CONFIRMED` et un `LINK_FOUND` issus de deux sources). Sans
  /// cette déduplication, l'UI construisait deux badges portant la même clé,
  /// ce qui fait tomber tout l'écran de recherche avec « Duplicate keys
  /// found ». `CONFIRMED` l'emporte sur `LINK_FOUND` ; à statut égal, le
  /// premier lien reçu est conservé.
  List<PlatformLink> get positiveLinks => dedupePositiveLinks(links);

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
      title: json['title'] as String? ?? '',
      artistNames: artists,
      album: json['album'] as String?,
      durationMs: (json['durationMs'] as num?)?.toInt(),
      releaseDate: json['releaseDate'] as String?,
      explicit: json['explicit'] as bool?,
      imageUrl: images.isEmpty ? null : images.first,
      isrc: json['isrc'] as String?,
      mbid: json['mbid'] as String?,
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
