import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../library/data/library_api.dart';
import '../../remote_download/data/remote_download_api.dart';
import '../../remote_download/domain/remote_download_models.dart';
import '../domain/catalog_models.dart';
import '../domain/track_install_state.dart';

/// Identité normalisée d'une piste (`titre|artiste`), utilisée pour rattacher
/// un job serveur au résultat catalogue affiché.
String trackIdentityKey(String title, String artist) =>
    '${_normalize(title)}|${_normalize(artist)}';

String _normalize(String? value) => (value ?? '')
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'\s+'), ' ');

/// Suivi des installations en cours, indexé par `canonicalKey` catalogue.
///
/// Ce contrôleur vit au niveau application, pas au niveau écran : quitter la
/// recherche n'annule ni le job serveur ni son suivi, et y revenir réaffiche
/// immédiatement l'état réel.
class TrackInstallController extends Notifier<Map<String, TrackInstallState>> {
  final Map<String, StreamSubscription<RemoteDownload>> _watchers = {};

  /// `canonicalKey` → identité normalisée, pour retrouver un job au retour.
  final Map<String, String> _identities = {};

  @override
  Map<String, TrackInstallState> build() {
    ref.onDispose(() {
      for (final subscription in _watchers.values) {
        unawaited(subscription.cancel());
      }
      _watchers.clear();
    });
    return const {};
  }

  TrackInstallState stateFor(String canonicalKey) =>
      state[canonicalKey] ?? TrackInstallState.idle;

  void _put(String canonicalKey, TrackInstallState value) {
    state = {...state, canonicalKey: value};
  }

  /// Lance l'installation d'un résultat catalogue précis.
  ///
  /// Aucune demande n'est créée et aucune URL n'est fournie : l'identité de la
  /// piste part au backend, qui résout seul les sources.
  Future<void> install(CatalogResult result) async {
    final key = result.canonicalKey;
    final current = stateFor(key);
    // Garde anti-double-clic : un job en vol ou une piste déjà installée ne
    // doit jamais produire un second téléchargement.
    if (current.stage.isBusy || current.stage.isInstalled) return;

    final artist = result.artistNames.isEmpty ? '' : result.artistNames.first;
    final label = artist.isEmpty ? result.title : '$artist – ${result.title}';
    _identities[key] = trackIdentityKey(result.title, artist);
    _put(
      key,
      TrackInstallState(
        stage: TrackInstallStage.creating,
        message: TrackInstallState.messageForStage(
          TrackInstallStage.creating,
          null,
        ),
        label: label,
      ),
    );

    final durationMs = result.durationMs;
    try {
      final outcome = await ref
          .read(remoteDownloadApiProvider)
          .searchAndDownload(
            query: [artist, result.title]
                .where((part) => part.trim().isNotEmpty)
                .join(' '),
            title: result.title,
            artist: artist,
            album: result.album,
            isrc: result.isrc,
            durationSeconds: durationMs == null || durationMs <= 0
                ? null
                : (durationMs / 1000).round(),
          );

      switch (outcome) {
        case RemoteDownloadQueued(:final job):
          _put(key, TrackInstallState.fromJob(job, label: label));
          _watch(key, job.id, label);
        case RemoteDownloadAmbiguous(:final message):
        case RemoteDownloadNoMatch(:final message):
          // L'identité était pourtant complète : le backend n'a trouvé aucune
          // source exploitable pour ce morceau.
          _put(
            key,
            TrackInstallState(
              stage: TrackInstallStage.failed,
              message: message ?? 'Aucune source disponible pour ce titre.',
              label: label,
            ),
          );
      }
    } on RemoteDownloadException catch (error) {
      logError('installation refusée', error: error);
      _put(
        key,
        TrackInstallState(
          stage: TrackInstallStage.failed,
          message: error.message,
          label: label,
        ),
      );
    }
  }

  /// Réessai après échec : repart d'un état neutre puis relance.
  Future<void> retry(CatalogResult result) async {
    final key = result.canonicalKey;
    if (stateFor(key).stage.isBusy) return;
    state = {...state}..remove(key);
    await install(result);
  }

  void _watch(String canonicalKey, String jobId, String label) {
    unawaited(_watchers.remove(canonicalKey)?.cancel());
    _watchers[canonicalKey] = ref
        .read(remoteDownloadApiProvider)
        .watchDownload(jobId)
        .listen(
          (job) {
            _put(canonicalKey, TrackInstallState.fromJob(job, label: label));
            if (job.status == RemoteDownloadStatus.completed) {
              // La bibliothèque vient de changer : « Lire maintenant » et le
              // badge « Dans ma bibliothèque » doivent le refléter aussitôt.
              ref.invalidate(libraryProvider);
            }
          },
          onError: (Object error) {
            logError('suivi d’installation interrompu', error: error);
            _put(
              canonicalKey,
              stateFor(canonicalKey).copyWith(
                stage: TrackInstallStage.failed,
                message: 'Le suivi de l’installation a été perdu.',
              ),
            );
          },
          onDone: () => _watchers.remove(canonicalKey),
        );
  }

  /// Rattache les jobs serveur encore actifs aux résultats actuellement
  /// affichés. Appelé à l'ouverture de l'écran et après chaque recherche.
  Future<void> restoreFor(List<CatalogResult> results) async {
    if (results.isEmpty) return;
    final List<RemoteDownload> jobs;
    try {
      jobs = await ref.read(remoteDownloadApiProvider).listDownloads(limit: 50);
    } on RemoteDownloadException {
      // Le moteur peut être absent de ce serveur : ne rien afficher vaut mieux
      // qu'une erreur pour une information d'appoint.
      return;
    }
    if (!ref.mounted) return;

    final byIdentity = <String, RemoteDownload>{};
    for (final job in jobs) {
      final identity = trackIdentityKey(job.title ?? '', job.artist ?? '');
      if (identity == '|') continue;
      // `listDownloads` est trié du plus récent au plus ancien : le premier vu
      // pour une identité est le job à afficher.
      byIdentity.putIfAbsent(identity, () => job);
    }

    for (final result in results) {
      final key = result.canonicalKey;
      if (stateFor(key).stage != TrackInstallStage.idle) continue;
      final artist = result.artistNames.isEmpty ? '' : result.artistNames.first;
      final job = byIdentity[trackIdentityKey(result.title, artist)];
      if (job == null) continue;
      final label = artist.isEmpty ? result.title : '$artist – ${result.title}';
      _identities[key] = trackIdentityKey(result.title, artist);
      _put(key, TrackInstallState.fromJob(job, label: label));
      if (job.status.isActive) _watch(key, job.id, label);
    }
  }
}

final trackInstallProvider =
    NotifierProvider<TrackInstallController, Map<String, TrackInstallState>>(
      TrackInstallController.new,
      name: 'trackInstall',
    );
