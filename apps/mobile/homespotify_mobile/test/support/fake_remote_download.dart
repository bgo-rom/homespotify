import 'dart:async';

import 'package:homespotify_mobile/src/features/remote_download/data/remote_download_api.dart';
import 'package:homespotify_mobile/src/features/remote_download/domain/remote_download_models.dart';

/// Corps réellement envoyé à `POST /api/downloads/search`.
///
/// Les tests vérifient que l'identité COMPLÈTE du résultat sélectionné part au
/// backend, et jamais une URL fournie par l'application.
class RecordedInstallCall {
  const RecordedInstallCall({
    required this.query,
    this.title,
    this.artist,
    this.album,
    this.isrc,
    this.durationSeconds,
  });

  final String query;
  final String? title;
  final String? artist;
  final String? album;
  final String? isrc;
  final int? durationSeconds;
}

RemoteDownload fakeJob({
  String id = 'job-1',
  RemoteDownloadStatus status = RemoteDownloadStatus.queued,
  int progress = 0,
  int attempt = 1,
  bool reused = false,
  int? trackId,
  String? errorMessage,
  String title = 'Lifestyles',
  String artist = 'Guala',
}) {
  return RemoteDownload(
    id: id,
    url: 'https://open.spotify.com/track/x',
    provider: 'antra',
    status: status,
    progress: progress,
    attempt: attempt,
    maxAttempts: 3,
    cancelRequested: false,
    reused: reused,
    title: title,
    artist: artist,
    trackId: trackId,
    errorMessage: errorMessage,
  );
}

/// Dépôt de téléchargement factice : aucun réseau, flux d'états pilotable.
class FakeRemoteDownloadRepository implements RemoteDownloadRepository {
  FakeRemoteDownloadRepository({
    this.outcome,
    this.failWith,
    List<RemoteDownload> timeline = const [],
    List<RemoteDownload> existingJobs = const [],
  }) : timeline = List.of(timeline),
       existingJobs = List.of(existingJobs);

  /// Réponse de `searchAndDownload`. Par défaut : job créé.
  RemoteDownloadSearchOutcome? outcome;

  /// Si non null, `searchAndDownload` lève cette exception.
  RemoteDownloadException? failWith;

  /// États successifs émis par le suivi SSE.
  List<RemoteDownload> timeline;

  /// Jobs déjà connus du serveur (reprise d'état au retour sur l'écran).
  List<RemoteDownload> existingJobs;

  final List<RecordedInstallCall> calls = [];

  @override
  Future<RemoteDownloadSearchOutcome> searchAndDownload({
    required String query,
    String? title,
    String? artist,
    String? album,
    String? isrc,
    int? durationSeconds,
  }) async {
    calls.add(
      RecordedInstallCall(
        query: query,
        title: title,
        artist: artist,
        album: album,
        isrc: isrc,
        durationSeconds: durationSeconds,
      ),
    );
    final error = failWith;
    if (error != null) throw error;
    return outcome ??
        RemoteDownloadQueued(
          job: fakeJob(),
          track: const RemoteDownloadTrackOption(
            key: 'k',
            title: 'Lifestyles',
            artist: 'Guala',
            confidence: 100,
          ),
        );
  }

  @override
  Stream<RemoteDownload> watchDownload(String jobId) async* {
    for (final job in timeline) {
      yield job;
    }
  }

  @override
  Future<List<RemoteDownload>> listDownloads({int limit = 20}) async =>
      List.of(existingJobs);

  @override
  Future<RemoteDownload> createDownload(String url) =>
      throw UnimplementedError();

  @override
  Future<RemoteDownload> fetchDownload(String jobId) =>
      throw UnimplementedError();

  @override
  Future<RemoteDownloadCancelResult> cancelDownload(String jobId) =>
      throw UnimplementedError();

  @override
  Future<RemoteDownload> retryDownload(String jobId) =>
      throw UnimplementedError();

  @override
  Future<RemoteDownloadHealth> fetchHealth() =>
      throw UnimplementedError();
}
