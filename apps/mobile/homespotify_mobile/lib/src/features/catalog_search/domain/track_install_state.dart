/// État d'installation d'UNE piste, tel qu'affiché dans sa carte de résultat.
///
/// Il n'existe plus de demande musicale : cliquer « Installer » déclenche
/// directement un job `download_jobs` côté serveur. Cet état n'est donc que la
/// projection lisible de ce job — jamais une file d'attente de validation.
library;

import '../../remote_download/domain/remote_download_models.dart';

/// Étapes visibles par l'utilisateur, dans l'ordre où elles surviennent.
enum TrackInstallStage {
  /// Rien n'a été demandé pour cette piste.
  idle,

  /// Requête partie, identifiant de job pas encore reçu.
  creating,

  /// Le serveur cherche les URL exploitables du morceau sélectionné.
  resolving,

  /// Téléchargement d'une source en cours.
  downloading,

  /// La première source a échoué, une autre est essayée.
  fallback,

  /// Fichier obtenu, remise au pipeline d'import du compte.
  importing,

  /// Piste ajoutée à la bibliothèque.
  success,

  /// Piste déjà présente : succès par déduplication, pas un échec.
  reused,

  /// Échec définitif : l'utilisateur peut réessayer.
  failed,
}

extension TrackInstallStageX on TrackInstallStage {
  /// Un job est en vol : tout nouveau clic doit être ignoré.
  bool get isBusy =>
      this == TrackInstallStage.creating ||
      this == TrackInstallStage.resolving ||
      this == TrackInstallStage.downloading ||
      this == TrackInstallStage.fallback ||
      this == TrackInstallStage.importing;

  /// La piste est en bibliothèque (installée ou réutilisée).
  bool get isInstalled =>
      this == TrackInstallStage.success || this == TrackInstallStage.reused;
}

class TrackInstallState {
  const TrackInstallState({
    required this.stage,
    this.jobId,
    this.progress = 0,
    this.message,
    this.attemptedSource,
    this.trackId,
    this.label = '',
  });

  static const TrackInstallState idle = TrackInstallState(
    stage: TrackInstallStage.idle,
  );

  final TrackInstallStage stage;

  /// UUID du job serveur. `null` tant que la création n'a pas répondu.
  final String? jobId;

  /// 0-100. Seule l'étape [TrackInstallStage.downloading] l'exploite.
  final int progress;

  /// Libellé français prêt à afficher, déjà assaini côté serveur.
  final String? message;

  /// Catalogue de l'URL en cours d'essai (`spotify`, `deezer`…).
  final String? attemptedSource;

  /// Identifiant de la piste en bibliothèque, une fois l'import abouti.
  final int? trackId;

  /// « Guala – Lifestyles », pour les messages de confirmation.
  final String label;

  TrackInstallState copyWith({
    TrackInstallStage? stage,
    String? jobId,
    int? progress,
    String? message,
    String? attemptedSource,
    int? trackId,
    String? label,
  }) {
    return TrackInstallState(
      stage: stage ?? this.stage,
      jobId: jobId ?? this.jobId,
      progress: progress ?? this.progress,
      message: message ?? this.message,
      attemptedSource: attemptedSource ?? this.attemptedSource,
      trackId: trackId ?? this.trackId,
      label: label ?? this.label,
    );
  }

  /// Projette un job serveur sur l'état affiché.
  ///
  /// Le repli entre sources n'est pas un statut backend distinct : il se lit à
  /// `attempt > 1`, c'est-à-dire « une source a déjà été essayée sans succès ».
  static TrackInstallState fromJob(RemoteDownload job, {required String label}) {
    final stage = switch (job.status) {
      RemoteDownloadStatus.completed =>
        job.reused ? TrackInstallStage.reused : TrackInstallStage.success,
      RemoteDownloadStatus.failed ||
      RemoteDownloadStatus.cancelled ||
      RemoteDownloadStatus.interrupted => TrackInstallStage.failed,
      RemoteDownloadStatus.importing ||
      RemoteDownloadStatus.processing => TrackInstallStage.importing,
      RemoteDownloadStatus.downloading =>
        job.attempt > 1 ? TrackInstallStage.fallback : TrackInstallStage.downloading,
      RemoteDownloadStatus.queued ||
      RemoteDownloadStatus.resolving ||
      RemoteDownloadStatus.unknown => TrackInstallStage.resolving,
    };
    return TrackInstallState(
      stage: stage,
      jobId: job.id,
      progress: job.progress,
      message: messageForStage(stage, job),
      attemptedSource: job.attemptedSource,
      trackId: job.trackId,
      label: label,
    );
  }

  /// Libellé d'étape. Les textes viennent de l'application, pas du moteur :
  /// aucun log brut, aucun chemin, aucun secret ne peut s'y glisser.
  static String messageForStage(TrackInstallStage stage, RemoteDownload? job) {
    switch (stage) {
      case TrackInstallStage.idle:
        return '';
      case TrackInstallStage.creating:
        return 'Préparation…';
      case TrackInstallStage.resolving:
        return 'Recherche des sources…';
      case TrackInstallStage.downloading:
        return 'Téléchargement…';
      case TrackInstallStage.fallback:
        return 'Première source indisponible, essai d’une autre source…';
      case TrackInstallStage.importing:
        return 'Ajout à votre bibliothèque…';
      case TrackInstallStage.success:
        return 'Installé dans votre bibliothèque.';
      case TrackInstallStage.reused:
        return 'Ce titre est déjà présent dans votre bibliothèque.';
      case TrackInstallStage.failed:
        return job?.errorMessage?.trim().isNotEmpty == true
            ? job!.errorMessage!
            : 'L’installation a échoué.';
    }
  }

  @override
  bool operator ==(Object other) =>
      other is TrackInstallState &&
      other.stage == stage &&
      other.jobId == jobId &&
      other.progress == progress &&
      other.message == message &&
      other.attemptedSource == attemptedSource &&
      other.trackId == trackId &&
      other.label == label;

  @override
  int get hashCode => Object.hash(
    stage,
    jobId,
    progress,
    message,
    attemptedSource,
    trackId,
    label,
  );
}
