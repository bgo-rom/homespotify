/// Modèles hors ligne (Phase 1A) — contrats TD-Offline-Opus-2026-07-22.
library;

/// Les trois choix présentés à chaque téléchargement. `original` n'est jamais
/// une dérivée : c'est la copie exacte servie par la route Range canonique.
enum OfflineProfile { opus128, opus256, original }

extension OfflineProfileWire on OfflineProfile {
  String get wire => switch (this) {
    OfflineProfile.opus128 => 'opus_128',
    OfflineProfile.opus256 => 'opus_256',
    OfflineProfile.original => 'original',
  };

  static OfflineProfile parse(String value) => switch (value) {
    'opus_128' => OfflineProfile.opus128,
    'opus_256' => OfflineProfile.opus256,
    'original' => OfflineProfile.original,
    _ => throw ArgumentError('Profil hors ligne inconnu : $value'),
  };
}

/// Une option de téléchargement telle que renvoyée par
/// `GET /api/tracks/:id/offline-options`. La taille est `estimated` tant que la
/// dérivée n'est pas prête ; `exact` pour une variante prête ou l'original.
class OfflineOption {
  const OfflineOption({
    required this.profile,
    required this.lossy,
    required this.status,
    required this.recommended,
    this.codec,
    this.container,
    this.qualityStatus,
    this.targetBitrateKbps,
    this.measuredBitrateKbps,
    this.durationSeconds,
    this.sizeBytes,
    this.sizeKind,
    this.sha256,
    required this.sourceSha256,
  });

  final OfflineProfile profile;

  /// `null` = caractère lossy inconnu (original sans analyse technique).
  final bool? lossy;
  final String status;
  final bool recommended;
  final String? codec;
  final String? container;

  /// Statut d'analyse de l'original (lossless_verifie | lossy | inconnue…).
  final String? qualityStatus;
  final int? targetBitrateKbps;
  final int? measuredBitrateKbps;
  final double? durationSeconds;
  final int? sizeBytes;

  /// `estimated` | `exact` | null (durée source inconnue).
  final String? sizeKind;
  final String? sha256;
  final String sourceSha256;

  bool get sizeIsEstimated => sizeKind == 'estimated';

  factory OfflineOption.fromJson(Map<String, dynamic> json) => OfflineOption(
    profile: OfflineProfileWire.parse(json['profile'] as String),
    lossy: json['lossy'] as bool?,
    status: (json['status'] as String?) ?? 'NOT_REQUESTED',
    recommended: (json['recommended'] as bool?) ?? false,
    codec: json['codec'] as String?,
    container: json['container'] as String?,
    qualityStatus: json['qualityStatus'] as String?,
    targetBitrateKbps: (json['targetBitrateKbps'] as num?)?.toInt(),
    measuredBitrateKbps: (json['measuredBitrateKbps'] as num?)?.toInt(),
    durationSeconds: (json['durationSeconds'] as num?)?.toDouble(),
    sizeBytes: (json['sizeBytes'] as num?)?.toInt(),
    sizeKind: json['sizeKind'] as String?,
    sha256: json['sha256'] as String?,
    sourceSha256: json['sourceSha256'] as String,
  );
}

/// État serveur d'une variante Opus (POST/GET offline-variants/:profile).
class OfflineVariantState {
  const OfflineVariantState({
    required this.profile,
    required this.status,
    required this.sourceSha256,
    this.sizeBytes,
    this.sizeKind,
    this.sha256,
    this.measuredBitrateKbps,
    this.errorHint,
  });

  final OfflineProfile profile;
  final String status; // PENDING | ENCODING | READY | FAILED | STALE
  final String sourceSha256;
  final int? sizeBytes;
  final String? sizeKind;
  final String? sha256;
  final int? measuredBitrateKbps;
  final String? errorHint;

  bool get isReady => status == 'READY';
  bool get isFailed => status == 'FAILED';

  factory OfflineVariantState.fromJson(Map<String, dynamic> json) =>
      OfflineVariantState(
        profile: OfflineProfileWire.parse(json['profile'] as String),
        status: json['status'] as String,
        sourceSha256: json['sourceSha256'] as String,
        sizeBytes: (json['sizeBytes'] as num?)?.toInt(),
        sizeKind: json['sizeKind'] as String?,
        sha256: json['sha256'] as String?,
        measuredBitrateKbps: (json['measuredBitrateKbps'] as num?)?.toInt(),
      );
}

/// Cycle de vie LOCAL d'un téléchargement (manifeste mobile).
enum OfflineDownloadStatus {
  waitingServer,
  downloading,
  verifying,
  ready,
  failed,
  cancelled,
  stale,
}

/// Ligne du manifeste SQLite, TOUJOURS partitionnée par compte. Aucun token.
class OfflineTrackRecord {
  const OfflineTrackRecord({
    required this.userId,
    required this.trackId,
    required this.profile,
    required this.sourceSha256,
    required this.status,
    required this.receivedBytes,
    this.expectedSha256,
    this.sizeBytes,
    this.relativePath,
    this.codec,
    this.container,
    this.lossy,
    this.measuredBitrateKbps,
    this.title,
    this.artist,
    this.album,
    this.durationSeconds,
    this.errorMessage,
    this.updatedAt,
    this.lastAccessedAt,
  });

  final int userId;
  final int trackId;
  final OfflineProfile profile;
  final String sourceSha256;
  final OfflineDownloadStatus status;
  final int receivedBytes;
  final String? expectedSha256;
  final int? sizeBytes;

  /// Chemin RELATIF au dossier hors ligne du compte — jamais absolu en base.
  final String? relativePath;
  final String? codec;
  final String? container;
  final bool? lossy;
  final int? measuredBitrateKbps;
  final String? title;
  final String? artist;
  final String? album;
  final double? durationSeconds;
  final String? errorMessage;
  final DateTime? updatedAt;
  final DateTime? lastAccessedAt;

  OfflineTrackRecord copyWith({
    OfflineDownloadStatus? status,
    int? receivedBytes,
    String? expectedSha256,
    int? sizeBytes,
    String? relativePath,
    String? errorMessage,
    DateTime? lastAccessedAt,
  }) => OfflineTrackRecord(
    userId: userId,
    trackId: trackId,
    profile: profile,
    sourceSha256: sourceSha256,
    status: status ?? this.status,
    receivedBytes: receivedBytes ?? this.receivedBytes,
    expectedSha256: expectedSha256 ?? this.expectedSha256,
    sizeBytes: sizeBytes ?? this.sizeBytes,
    relativePath: relativePath ?? this.relativePath,
    codec: codec,
    container: container,
    lossy: lossy,
    measuredBitrateKbps: measuredBitrateKbps,
    title: title,
    artist: artist,
    album: album,
    durationSeconds: durationSeconds,
    errorMessage: errorMessage ?? this.errorMessage,
    updatedAt: updatedAt,
    lastAccessedAt: lastAccessedAt ?? this.lastAccessedAt,
  );
}

/// Progression d'un téléchargement pour l'UI.
class OfflineDownloadProgress {
  const OfflineDownloadProgress({
    required this.status,
    required this.receivedBytes,
    this.totalBytes,
    this.message,
  });

  final OfflineDownloadStatus status;
  final int receivedBytes;
  final int? totalBytes;
  final String? message;

  double? get ratio => totalBytes == null || totalBytes! <= 0
      ? null
      : (receivedBytes / totalBytes!).clamp(0.0, 1.0);
}

enum OfflineGroupType { album, playlist }

enum OfflineGroupStatus {
  queued,
  waitingNetwork,
  running,
  paused,
  completed,
  partial,
  cancelled,
}

enum OfflineGroupItemStatus { queued, running, ready, failed, cancelled }

/// Job persistant regroupant les copies locales d'un album ou d'une playlist.
/// L'encodage reste unitaire et mutualisé côté serveur ; ce job orchestre
/// uniquement la préparation et les transferts du téléphone.
class OfflineDownloadGroup {
  const OfflineDownloadGroup({
    required this.id,
    required this.userId,
    required this.type,
    required this.sourceId,
    required this.title,
    required this.profile,
    required this.status,
    required this.totalItems,
    required this.completedItems,
    required this.failedItems,
    required this.estimatedBytes,
    required this.exactBytes,
    required this.createdAt,
    required this.updatedAt,
    this.errorMessage,
  });

  final String id;
  final int userId;
  final OfflineGroupType type;
  final String sourceId;
  final String title;
  final OfflineProfile profile;
  final OfflineGroupStatus status;
  final int totalItems;
  final int completedItems;
  final int failedItems;
  final int estimatedBytes;
  final int exactBytes;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? errorMessage;

  int get remainingItems =>
      (totalItems - completedItems - failedItems).clamp(0, totalItems).toInt();

  double get ratio => totalItems <= 0
      ? 0
      : ((completedItems + failedItems) / totalItems)
            .clamp(0.0, 1.0)
            .toDouble();

  OfflineDownloadGroup copyWith({
    OfflineGroupStatus? status,
    int? completedItems,
    int? failedItems,
    int? exactBytes,
    DateTime? updatedAt,
    String? errorMessage,
    bool clearError = false,
  }) => OfflineDownloadGroup(
    id: id,
    userId: userId,
    type: type,
    sourceId: sourceId,
    title: title,
    profile: profile,
    status: status ?? this.status,
    totalItems: totalItems,
    completedItems: completedItems ?? this.completedItems,
    failedItems: failedItems ?? this.failedItems,
    estimatedBytes: estimatedBytes,
    exactBytes: exactBytes ?? this.exactBytes,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
  );
}

class OfflineDownloadGroupItem {
  const OfflineDownloadGroupItem({
    required this.groupId,
    required this.position,
    required this.trackId,
    required this.status,
    required this.title,
    required this.artist,
    required this.album,
    required this.sourceSha256,
    this.durationSeconds,
    this.sizeBytes,
    this.mimeType,
    this.extension,
    this.errorMessage,
  });

  final String groupId;
  final int position;
  final int trackId;
  final OfflineGroupItemStatus status;
  final String title;
  final String artist;
  final String album;
  final String sourceSha256;
  final double? durationSeconds;
  final int? sizeBytes;
  final String? mimeType;
  final String? extension;
  final String? errorMessage;

  OfflineDownloadGroupItem copyWith({
    OfflineGroupItemStatus? status,
    String? errorMessage,
    bool clearError = false,
  }) => OfflineDownloadGroupItem(
    groupId: groupId,
    position: position,
    trackId: trackId,
    status: status ?? this.status,
    title: title,
    artist: artist,
    album: album,
    sourceSha256: sourceSha256,
    durationSeconds: durationSeconds,
    sizeBytes: sizeBytes,
    mimeType: mimeType,
    extension: extension,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
  );
}
