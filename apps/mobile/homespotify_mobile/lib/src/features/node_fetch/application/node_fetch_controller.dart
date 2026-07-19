import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../library/data/library_api.dart';
import '../../library/presentation/library_summary.dart';
import '../data/node_fetch_api.dart';

const String nodeFetchAcceptedMessage =
    'La requête a été envoyée au serveur et est en cours de traitement en arrière-plan.';

enum NodeFetchPhase {
  idle,
  submitting,
  queued,
  fetching,
  readyForImport,
  monitoringPaused,
  failed,
}

class NodeFetchState {
  const NodeFetchState({
    this.phase = NodeFetchPhase.idle,
    this.message,
    this.jobId,
    this.filename,
    this.bytesReceived = 0,
  });

  final NodeFetchPhase phase;
  final String? message;
  final String? jobId;
  final String? filename;
  final int bytesReceived;

  bool get isActive => switch (phase) {
    NodeFetchPhase.submitting ||
    NodeFetchPhase.queued ||
    NodeFetchPhase.fetching ||
    NodeFetchPhase.monitoringPaused => true,
    _ => false,
  };
}

final nodeFetchPollIntervalProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 1),
);

final nodeFetchMaxPollAttemptsProvider = Provider<int>((ref) => 720);

final nodeFetchLibraryRefreshDelaysProvider = Provider<List<Duration>>(
  (ref) => const [Duration.zero, Duration(seconds: 3), Duration(seconds: 8)],
);

class NodeFetchController extends Notifier<NodeFetchState> {
  int _generation = 0;

  NodeFetchRepository get _api => ref.read(nodeFetchApiProvider);

  @override
  NodeFetchState build() {
    ref.onDispose(() => _generation += 1);
    return const NodeFetchState();
  }

  Future<void> submit({required String url, required int userId}) async {
    if (state.isActive) return;
    final parsed = Uri.tryParse(url.trim());
    if (parsed == null ||
        parsed.scheme != 'https' ||
        !parsed.hasAuthority ||
        parsed.userInfo.isNotEmpty) {
      state = const NodeFetchState(
        phase: NodeFetchPhase.failed,
        message: 'Saisis une URL HTTPS valide sans identifiants intégrés.',
      );
      return;
    }

    final generation = ++_generation;
    state = const NodeFetchState(
      phase: NodeFetchPhase.submitting,
      message: 'Envoi de la requête au serveur…',
    );
    try {
      final job = await _api.enqueue(url: parsed.toString(), userId: userId);
      if (generation != _generation) return;
      state = NodeFetchState(
        phase: NodeFetchPhase.queued,
        message: nodeFetchAcceptedMessage,
        jobId: job.id,
      );
      unawaited(_poll(job.id, generation));
    } on NodeFetchApiException catch (error) {
      if (generation != _generation) return;
      state = NodeFetchState(
        phase: NodeFetchPhase.failed,
        message: error.message,
      );
    }
  }

  Future<void> resumeMonitoring() async {
    final jobId = state.jobId;
    if (jobId == null || jobId.isEmpty) return;
    final generation = ++_generation;
    state = NodeFetchState(
      phase: NodeFetchPhase.fetching,
      message: 'Reprise du suivi de l’import…',
      jobId: jobId,
      filename: state.filename,
      bytesReceived: state.bytesReceived,
    );
    await _poll(jobId, generation);
  }

  void reset() {
    _generation += 1;
    state = const NodeFetchState();
  }

  Future<void> _poll(String jobId, int generation) async {
    final interval = ref.read(nodeFetchPollIntervalProvider);
    final maxAttempts = ref.read(nodeFetchMaxPollAttemptsProvider);
    var consecutiveErrors = 0;
    for (var attempt = 0; attempt < maxAttempts; attempt += 1) {
      await Future<void>.delayed(interval);
      if (generation != _generation) return;
      try {
        final job = await _api.fetchJob(jobId);
        if (generation != _generation) return;
        consecutiveErrors = 0;
        if (_applyJob(job, generation)) return;
      } on NodeFetchApiException {
        consecutiveErrors += 1;
        if (consecutiveErrors >= 3) {
          state = NodeFetchState(
            phase: NodeFetchPhase.monitoringPaused,
            message:
                'Le suivi réseau est interrompu, mais le traitement serveur peut continuer.',
            jobId: jobId,
          );
          return;
        }
      }
    }
    if (generation == _generation) {
      state = NodeFetchState(
        phase: NodeFetchPhase.monitoringPaused,
        message:
            'Le traitement continue en arrière-plan. Reprends le suivi plus tard.',
        jobId: jobId,
      );
    }
  }

  bool _applyJob(NodeFetchJob job, int generation) {
    switch (job.status) {
      case NodeFetchJobStatus.queued:
        state = NodeFetchState(
          phase: NodeFetchPhase.queued,
          message: nodeFetchAcceptedMessage,
          jobId: job.id,
        );
        return false;
      case NodeFetchJobStatus.fetching:
        state = NodeFetchState(
          phase: NodeFetchPhase.fetching,
          message: 'Le serveur récupère le fichier vers ton inbox…',
          jobId: job.id,
          bytesReceived: job.bytesReceived,
        );
        return false;
      case NodeFetchJobStatus.readyForImport:
        state = NodeFetchState(
          phase: NodeFetchPhase.readyForImport,
          message:
              'Le fichier a été déposé dans l’inbox. Le watcher HomeSpotify termine son analyse et son import.',
          jobId: job.id,
          filename: job.filename,
          bytesReceived: job.bytesReceived,
        );
        unawaited(_refreshLibrary(generation));
        return true;
      case NodeFetchJobStatus.failed:
        state = NodeFetchState(
          phase: NodeFetchPhase.failed,
          message: job.errorMessage ?? 'L’import distant a échoué.',
          jobId: job.id,
        );
        return true;
    }
  }

  Future<void> _refreshLibrary(int generation) async {
    for (final delay in ref.read(nodeFetchLibraryRefreshDelaysProvider)) {
      await Future<void>.delayed(delay);
      if (generation != _generation) return;
      ref.invalidate(libraryProvider);
      ref.invalidate(userLibrarySummaryProvider);
    }
  }
}

final nodeFetchControllerProvider =
    NotifierProvider<NodeFetchController, NodeFetchState>(
      NodeFetchController.new,
    );
