/// Modèles du téléchargement par lien (miroir strict du contrat backend
/// `/api/downloads/*`).
///
/// Le backend n'expose JAMAIS de chemin serveur, de PID, de commande, de
/// `stderr` brut ni la clé Premium du moteur : ces modèles ne prévoient donc
/// aucun champ de ce type, et un champ inattendu est ignoré.
library;

/// Statut d'un téléchargement.
///
/// Le wire est en minuscules côté backend (`DOWNLOAD_JOB_STATUSES`). Une valeur
/// inconnue — backend plus récent que l'app — devient [unknown] au lieu de
/// lever : l'écran doit rester affichable après une mise à jour serveur.
enum RemoteDownloadStatus {
  queued('queued', 'En attente'),
  resolving('resolving', 'Recherche de la piste'),
  downloading('downloading', 'Téléchargement'),
  processing('processing', 'Finalisation'),
  importing('importing', 'Ajout à la bibliothèque'),
  completed('completed', 'Terminé'),
  failed('failed', 'Échec'),
  cancelled('cancelled', 'Annulé'),
  interrupted('interrupted', 'Interrompu'),
  unknown('unknown', 'État inconnu');

  const RemoteDownloadStatus(this.wireName, this.label);

  /// Valeur exacte échangée avec le backend.
  final String wireName;

  /// Libellé français court, utilisable tel quel par l'UI.
  final String label;

  static RemoteDownloadStatus fromWire(String? raw) => values.firstWhere(
    (value) => value.wireName == raw,
    orElse: () => unknown,
  );

  /// Plus aucune transition n'est attendue : le suivi peut s'arrêter.
  bool get isTerminal =>
      this == completed ||
      this == failed ||
      this == cancelled ||
      this == interrupted;

  /// Le téléchargement progresse encore côté serveur.
  ///
  /// [unknown] est délibérément considéré comme actif : un statut non reconnu
  /// ne doit pas faire croire à tort que le travail est fini.
  bool get isActive => !isTerminal;

  /// Une annulation a un sens dans cet état.
  bool get isCancellable => isActive;

  /// Seuls ces états peuvent être relancés — jamais un succès ni une annulation
  /// volontaire.
  bool get isRetryable => this == failed || this == interrupted;
}

/// Téléchargement tel qu'exposé par l'API (`publicDownloadJob`).
class RemoteDownload {
  const RemoteDownload({
    required this.id,
    required this.url,
    required this.provider,
    required this.status,
    required this.progress,
    required this.attempt,
    required this.maxAttempts,
    required this.cancelRequested,
    this.reused = false,
    this.stage,
    this.message,
    this.title,
    this.artist,
    this.album,
    this.source,
    this.quality,
    this.attemptedSource,
    this.query,
    this.trackId,
    this.errorCode,
    this.errorMessage,
    this.createdAt,
    this.updatedAt,
    this.startedAt,
    this.completedAt,
  });

  /// UUID généré par le serveur.
  final String id;
  final String url;

  /// Toujours `antra` aujourd'hui ; conservé en `String` pour ne pas casser
  /// l'app si un second moteur est branché plus tard.
  final String provider;
  final RemoteDownloadStatus status;

  /// Étape technique libre côté serveur. Jamais affichée seule :
  /// [RemoteDownloadStatus.label] fait foi.
  final String? stage;
  final int progress;
  final String? message;
  final String? title;
  final String? artist;
  final String? album;
  final String? source;
  final String? quality;

  /// Catalogue de l’URL en cours d’essai (`spotify`, `deezer`…) : rend le
  /// repli entre sources lisible à l’écran.
  final String? attemptedSource;

  /// Texte recherché, quand le job vient d’une recherche.
  final String? query;
  final int attempt;
  final int maxAttempts;
  final bool cancelRequested;

  /// Succès obtenu en réutilisant une piste déjà indexée (déduplication).
  /// Ce n'est PAS un échec : l'installation est aboutie, le fichier existait.
  final bool reused;

  /// Identifiant de la piste réellement présente en bibliothèque. Renseigné
  /// uniquement quand le pipeline local a abouti.
  final int? trackId;
  final String? errorCode;

  /// Message d'échec déjà traduit et assaini par le backend.
  final String? errorMessage;

  /// Dates ISO 8601 UTC. Nullables sans exception : une date illisible ne doit
  /// jamais empêcher d'afficher l'état.
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? startedAt;
  final DateTime? completedAt;

  /// Le fichier est en bibliothèque et lisible.
  bool get isImported =>
      status == RemoteDownloadStatus.completed && trackId != null;

  /// Une annulation est demandée mais pas encore effective.
  bool get isCancelling => cancelRequested && status.isActive;

  /// Libellé « Artiste — Titre » quand il est connu, sinon l'adresse soumise.
  String get displayLabel {
    final trimmedTitle = title?.trim() ?? '';
    final trimmedArtist = artist?.trim() ?? '';
    if (trimmedTitle.isEmpty) return url;
    if (trimmedArtist.isEmpty) return trimmedTitle;
    return '$trimmedArtist — $trimmedTitle';
  }

  static RemoteDownload fromJson(Map<String, dynamic> json) {
    return RemoteDownload(
      id: _asString(json['id']) ?? '',
      url: _asString(json['url']) ?? '',
      provider: _asString(json['provider']) ?? 'antra',
      status: RemoteDownloadStatus.fromWire(_asString(json['status'])),
      stage: _asString(json['stage']),
      progress: (_asInt(json['progress']) ?? 0).clamp(0, 100),
      message: _asString(json['message']),
      title: _asString(json['title']),
      artist: _asString(json['artist']),
      album: _asString(json['album']),
      source: _asString(json['source']),
      quality: _asString(json['quality']),
      attemptedSource: _asString(json['attemptedSource']),
      query: _asString(json['query']),
      attempt: _asInt(json['attempt']) ?? 0,
      maxAttempts: _asInt(json['maxAttempts']) ?? 1,
      cancelRequested: json['cancelRequested'] == true,
      reused: json['reused'] == true,
      trackId: _asInt(json['trackId']),
      errorCode: _asString(json['errorCode']),
      errorMessage: _asString(json['errorMessage']),
      createdAt: _asDate(json['createdAt']),
      updatedAt: _asDate(json['updatedAt']),
      startedAt: _asDate(json['startedAt']),
      completedAt: _asDate(json['completedAt']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RemoteDownload &&
      other.id == id &&
      other.status == status &&
      other.progress == progress &&
      other.stage == stage &&
      other.cancelRequested == cancelRequested &&
      other.reused == reused &&
      other.attempt == attempt &&
      other.attemptedSource == attemptedSource &&
      other.trackId == trackId &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(
    id,
    status,
    progress,
    stage,
    cancelRequested,
    reused,
    attempt,
    attemptedSource,
    trackId,
    updatedAt,
  );
}

/// Disponibilité du moteur, telle que rapportée par `/api/downloads/health`.
///
/// [premiumKeyConfigured] est un BOOLÉEN : le backend ne renvoie jamais la clé,
/// sa longueur ni son préfixe.
class RemoteDownloadHealth {
  const RemoteDownloadHealth({
    required this.available,
    required this.configured,
    this.premiumKeyConfigured = false,
    this.soulseekDisabled = true,
    this.detail,
  });

  const RemoteDownloadHealth.unknown()
    : available = false,
      configured = false,
      premiumKeyConfigured = false,
      soulseekDisabled = true,
      detail = null;

  final bool available;

  /// `false` = fonctionnalité absente du serveur : masquer l'entrée plutôt que
  /// signaler une panne.
  final bool configured;
  final bool premiumKeyConfigured;
  final bool soulseekDisabled;
  final String? detail;

  static RemoteDownloadHealth fromJson(Map<String, dynamic> json) {
    return RemoteDownloadHealth(
      available: json['available'] == true,
      configured: json['configured'] == true,
      premiumKeyConfigured: json['premiumKeyConfigured'] == true,
      soulseekDisabled: json['soulseekDisabled'] != false,
      detail: _asString(json['detail']),
    );
  }
}

/// Piste proposée par la recherche musicale (`publicResolvedTrack`).
///
/// Antra ne sait pas rechercher : le backend a résolu le texte en URL
/// candidates via le catalogue de découverte. `downloadUrl` est l'URL du
/// meilleur candidat — c'est elle que l'app renvoie pour un choix manuel.
class RemoteDownloadTrackOption {
  const RemoteDownloadTrackOption({
    required this.key,
    required this.title,
    required this.artist,
    required this.confidence,
    this.album,
    this.durationSeconds,
    this.isrc,
    this.artworkUrl,
    this.downloadUrl,
    this.sources = const [],
  });

  /// Clé canonique du catalogue (`isrc:…` / `id:…`).
  final String key;
  final String title;
  final String artist;
  final String? album;
  final int? durationSeconds;
  final String? isrc;

  /// Score de correspondance calculé par le backend (0-100).
  final int confidence;
  final String? artworkUrl;

  /// URL du meilleur candidat, à renvoyer pour lancer ce choix précis.
  final String? downloadUrl;

  /// Services d'où proviennent les URL candidates, dans l'ordre d'essai.
  final List<String> sources;

  String get label => artist.trim().isEmpty ? title : '$artist — $title';

  /// Durée lisible `m:ss`. `null` quand le catalogue ne la fournit pas.
  String? get durationLabel {
    final seconds = durationSeconds;
    if (seconds == null || seconds <= 0) return null;
    final minutes = seconds ~/ 60;
    final rest = (seconds % 60).toString().padLeft(2, '0');
    return '$minutes:$rest';
  }

  static RemoteDownloadTrackOption fromJson(Map<String, dynamic> json) {
    return RemoteDownloadTrackOption(
      key: _asString(json['key']) ?? '',
      title: _asString(json['title']) ?? '',
      artist: _asString(json['artist']) ?? '',
      album: _asString(json['album']),
      durationSeconds: _asInt(json['durationSeconds']),
      isrc: _asString(json['isrc']),
      confidence: (_asInt(json['confidence']) ?? 0).clamp(0, 100),
      artworkUrl: _asString(json['artworkUrl']),
      downloadUrl: _asString(json['downloadUrl']),
      sources: (json['sources'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(growable: false),
    );
  }
}

/// Issue d'une recherche `/api/downloads/search`.
sealed class RemoteDownloadSearchOutcome {
  const RemoteDownloadSearchOutcome();
}

/// Une piste s'est détachée : un job a été créé côté serveur.
class RemoteDownloadQueued extends RemoteDownloadSearchOutcome {
  const RemoteDownloadQueued({required this.job, required this.track});

  final RemoteDownload job;
  final RemoteDownloadTrackOption track;
}

/// Plusieurs pistes crédibles : l'utilisateur doit choisir. Aucun job créé.
class RemoteDownloadAmbiguous extends RemoteDownloadSearchOutcome {
  const RemoteDownloadAmbiguous({required this.options, this.message});

  final List<RemoteDownloadTrackOption> options;
  final String? message;
}

/// Aucune piste correspondante.
class RemoteDownloadNoMatch extends RemoteDownloadSearchOutcome {
  const RemoteDownloadNoMatch({this.message});

  final String? message;
}

/// Réponse d'une demande d'annulation.
///
/// [accepted] distingue une annulation réellement enregistrée (202) d'un job
/// déjà terminal pour lequel il n'y avait rien à annuler (200).
class RemoteDownloadCancelResult {
  const RemoteDownloadCancelResult({
    required this.accepted,
    required this.jobId,
    required this.status,
  });

  final bool accepted;
  final String jobId;
  final RemoteDownloadStatus status;

  static RemoteDownloadCancelResult fromJson(Map<String, dynamic> json) {
    return RemoteDownloadCancelResult(
      accepted: json['accepted'] == true,
      jobId: _asString(json['jobId']) ?? '',
      status: RemoteDownloadStatus.fromWire(_asString(json['status'])),
    );
  }
}

String? _asString(Object? value) => value is String ? value : null;

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}

DateTime? _asDate(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;
