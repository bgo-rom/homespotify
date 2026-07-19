/// Modèles de la découverte par swipe et des demandes de musique.
///
/// Côté mobile il n'existe AUCUNE notion de téléchargement : un candidat est
/// une fiche descriptive, une demande est un souhait traité manuellement par
/// le propriétaire du serveur.
library;

/// Candidat proposé sur une carte de l'écran « Découvrir ».
class RecommendationCandidate {
  const RecommendationCandidate({
    required this.id,
    required this.title,
    required this.artist,
    this.album,
    this.artworkUrl,
    this.previewUrl,
    this.durationMs,
    this.genres = const [],
    this.reason,
    this.reasonCode,
  });

  final int id;
  final String title;
  final String artist;
  final String? album;
  final String? artworkUrl;
  final String? previewUrl;
  final int? durationMs;
  final List<String> genres;

  /// Explication courte de la recommandation (« Parce que… »), optionnelle.
  final String? reason;

  /// Code stable de la raison (TOP_ARTIST, NEAR_FAVORITES, …), optionnel.
  final String? reasonCode;

  factory RecommendationCandidate.fromJson(Map<String, dynamic> json) {
    final genres = json['genres'];
    return RecommendationCandidate(
      id: (json['id'] as num).toInt(),
      title: json['title'] as String? ?? '',
      artist: json['artist'] as String? ?? '',
      album: json['album'] as String?,
      artworkUrl: json['artworkUrl'] as String?,
      previewUrl: json['previewUrl'] as String?,
      durationMs: (json['durationMs'] as num?)?.toInt(),
      genres: genres is List ? genres.whereType<String>().toList() : const [],
      reason: json['reason'] as String?,
      reasonCode: json['reasonCode'] as String?,
    );
  }
}

/// Page de la file pré-calculée servie par le backend (pagination curseur).
class RecommendationPage {
  const RecommendationPage({required this.items, this.nextCursor});

  final List<RecommendationCandidate> items;

  /// Curseur opaque de la page suivante ; null quand la file est épuisée.
  final String? nextCursor;

  factory RecommendationPage.fromJson(Map<String, dynamic> json) {
    final items = json['items'] as List<dynamic>? ?? const [];
    return RecommendationPage(
      items: items
          .whereType<Map<String, dynamic>>()
          .map(RecommendationCandidate.fromJson)
          .toList(growable: false),
      nextCursor: json['nextCursor'] as String?,
    );
  }
}

/// État de la file de recommandations (endpoint /api/recommendations/status).
/// État de génération de la file (miroir du backend).
enum RecommendationGenerationStatus { empty, ready, refreshing, exhausted }

RecommendationGenerationStatus _generationFromWire(String? raw) {
  return switch (raw) {
    'READY' => RecommendationGenerationStatus.ready,
    'REFRESHING' => RecommendationGenerationStatus.refreshing,
    'EXHAUSTED' => RecommendationGenerationStatus.exhausted,
    _ => RecommendationGenerationStatus.empty,
  };
}

class RecommendationQueueStatus {
  const RecommendationQueueStatus({
    required this.queueSize,
    required this.refreshing,
    this.readyCount = 0,
    this.reserveCount = 0,
    this.generationStatus = RecommendationGenerationStatus.empty,
    this.lastGeneratedAt,
    this.modelVersion,
    this.lastErrorKind,
  });

  final int queueSize;

  /// Cartes prêtes (extrait fiable, pas encore vues) côté feed standard.
  final int readyCount;

  /// Cartes en réserve (pas encore vues, toutes portes confondues).
  final int reserveCount;

  final RecommendationGenerationStatus generationStatus;

  /// true : le job asynchrone de régénération tourne côté serveur.
  final bool refreshing;
  final DateTime? lastGeneratedAt;
  final String? modelVersion;

  /// Type de la dernière erreur de refresh (`lastError.kind` du backend) :
  /// `PROVIDER_ERROR` | `SCHEMA_ERROR` | `UNKNOWN_ERROR` | `INSUFFICIENT_PROFILE`.
  /// Null si aucune erreur. Un état d'erreur est TERMINAL pour le sondage.
  final String? lastErrorKind;

  /// Le job de préparation est-il arrivé à un état TERMINAL ? On arrête alors
  /// le sondage adaptatif et on recharge immédiatement le feed. Terminal si :
  /// le job ne tourne plus, la file est prête/épuisée, ou une erreur est posée.
  bool get isTerminal {
    if (!refreshing) return true;
    if (lastErrorKind != null) return true;
    return generationStatus == RecommendationGenerationStatus.ready ||
        generationStatus == RecommendationGenerationStatus.exhausted;
  }

  /// Libellé court et stable pour la journalisation des transitions.
  String get pollLabel {
    if (lastErrorKind != null) return lastErrorKind!;
    return switch (generationStatus) {
      RecommendationGenerationStatus.ready => 'READY',
      RecommendationGenerationStatus.refreshing => 'REFRESHING',
      RecommendationGenerationStatus.exhausted => 'EXHAUSTED',
      RecommendationGenerationStatus.empty =>
        refreshing ? 'REFRESHING' : 'EMPTY',
    };
  }

  factory RecommendationQueueStatus.fromJson(Map<String, dynamic> json) {
    final lastError = json['lastError'];
    return RecommendationQueueStatus(
      queueSize: (json['queueSize'] as num?)?.toInt() ?? 0,
      readyCount: (json['readyCount'] as num?)?.toInt() ?? 0,
      reserveCount: (json['reserveCount'] as num?)?.toInt() ?? 0,
      generationStatus: _generationFromWire(
        json['generationStatus'] as String?,
      ),
      refreshing: json['refreshing'] as bool? ?? false,
      lastGeneratedAt: DateTime.tryParse(
        json['lastGeneratedAt'] as String? ?? '',
      ),
      modelVersion: json['modelVersion'] as String?,
      lastErrorKind: lastError is Map<String, dynamic>
          ? lastError['kind'] as String?
          : null,
    );
  }
}

/// Actions de swipe reconnues par le backend.
enum RecommendationSwipeAction {
  like,
  dislike,
  skip,
  open,
  request,
  previewStoppedEarly,
}

extension RecommendationSwipeActionWire on RecommendationSwipeAction {
  String get wireName => switch (this) {
    RecommendationSwipeAction.like => 'LIKE',
    RecommendationSwipeAction.dislike => 'DISLIKE',
    RecommendationSwipeAction.skip => 'SKIP',
    RecommendationSwipeAction.open => 'OPEN',
    RecommendationSwipeAction.request => 'REQUEST',
    RecommendationSwipeAction.previewStoppedEarly => 'PREVIEW_STOPPED_EARLY',
  };
}

/// Statuts métier d'une demande de musique (miroir du backend).
enum MusicRequestStatus {
  sent('SENT', 'Demande envoyée'),
  reviewing('REVIEWING', 'En cours de traitement'),
  approved('APPROVED', 'En cours de traitement'),
  searchingManually('SEARCHING_MANUALLY', 'En cours de traitement'),
  importing('IMPORTING', 'En cours de traitement'),
  partiallyCompleted('PARTIALLY_COMPLETED', 'Ajout partiel'),
  completed('COMPLETED', 'Ajoutée à votre bibliothèque'),
  rejected('REJECTED', 'Demande refusée'),
  cancelled('CANCELLED', 'Demande annulée'),
  failed('FAILED', 'Erreur'),
  unknown('UNKNOWN', 'Statut inconnu');

  const MusicRequestStatus(this.wireName, this.label);

  final String wireName;

  /// Libellé métier lisible, affiché tel quel dans « Mes demandes ».
  final String label;

  static MusicRequestStatus fromWire(String? raw) {
    for (final status in values) {
      if (status.wireName == raw) return status;
    }
    return MusicRequestStatus.unknown;
  }

  /// Annulable uniquement AVANT l'import (règle backend, dupliquée pour l'UI).
  bool get isCancellable => switch (this) {
    sent || reviewing || approved || searchingManually => true,
    _ => false,
  };

  /// La demande est encore vivante (le polling s'y intéresse).
  bool get isActive => isCancellable || this == importing;
}

enum MusicRequestType {
  track('TRACK', 'Morceau'),
  album('ALBUM', 'Album'),
  playlist('PLAYLIST', 'Playlist');

  const MusicRequestType(this.wireName, this.label);

  final String wireName;
  final String label;

  static MusicRequestType fromWire(String? raw) => values.firstWhere(
    (value) => value.wireName == raw,
    orElse: () => MusicRequestType.track,
  );
}

class MusicRequestItem {
  const MusicRequestItem({
    required this.id,
    required this.position,
    required this.title,
    required this.status,
    required this.presentInRequesterLibrary,
    this.artist,
    this.album,
    this.durationMs,
    this.resultingTrackId,
  });

  factory MusicRequestItem.fromJson(Map<String, dynamic> json) =>
      MusicRequestItem(
        id: (json['id'] as num).toInt(),
        position: (json['position'] as num?)?.toInt() ?? 0,
        title: json['title'] as String? ?? '',
        artist: json['artist'] as String?,
        album: json['album'] as String?,
        durationMs: (json['durationMs'] as num?)?.toInt(),
        resultingTrackId: (json['resultingTrackId'] as num?)?.toInt(),
        status: json['status'] as String? ?? 'PENDING',
        presentInRequesterLibrary:
            json['presentInRequesterLibrary'] as bool? ?? false,
      );

  final int id;
  final int position;
  final String title;
  final String? artist;
  final String? album;
  final int? durationMs;
  final int? resultingTrackId;
  final String status;
  final bool presentInRequesterLibrary;
}

class MusicRequest {
  const MusicRequest({
    required this.id,
    required this.candidateId,
    required this.title,
    required this.artist,
    required this.status,
    this.requestType = MusicRequestType.track,
    this.album,
    this.artworkUrl,
    this.ownerNote,
    this.resultingTrackId,
    this.createdAt,
    this.completedAt,
    this.externalUrl,
    this.externalSource,
    this.requestedItemCount = 0,
    this.completedItemCount = 0,
    this.unavailableItemCount = 0,
    this.items = const [],
  });

  final int id;
  final int candidateId;
  final String title;
  final String artist;
  final String? album;
  final String? artworkUrl;
  final MusicRequestStatus status;
  final MusicRequestType requestType;
  final String? ownerNote;
  final int? resultingTrackId;
  final DateTime? createdAt;
  final DateTime? completedAt;
  final String? externalUrl;
  final String? externalSource;
  final int requestedItemCount;
  final int completedItemCount;
  final int unavailableItemCount;
  final List<MusicRequestItem> items;

  factory MusicRequest.fromJson(Map<String, dynamic> json) {
    return MusicRequest(
      id: (json['id'] as num).toInt(),
      candidateId: (json['candidateId'] as num?)?.toInt() ?? 0,
      title: json['title'] as String? ?? '',
      artist: json['artist'] as String? ?? '',
      album: json['album'] as String?,
      artworkUrl: json['artworkUrl'] as String?,
      status: MusicRequestStatus.fromWire(json['status'] as String?),
      requestType: MusicRequestType.fromWire(
        json['requestType'] as String? ?? json['itemType'] as String?,
      ),
      ownerNote: json['ownerNote'] as String?,
      resultingTrackId: (json['resultingTrackId'] as num?)?.toInt(),
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
      completedAt: DateTime.tryParse(json['completedAt'] as String? ?? ''),
      externalUrl: json['externalUrl'] as String?,
      externalSource: json['externalSource'] as String?,
      requestedItemCount: (json['requestedItemCount'] as num?)?.toInt() ?? 0,
      completedItemCount: (json['completedItemCount'] as num?)?.toInt() ?? 0,
      unavailableItemCount:
          (json['unavailableItemCount'] as num?)?.toInt() ?? 0,
      items: (json['items'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(MusicRequestItem.fromJson)
          .toList(growable: false),
    );
  }
}
