import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../library/data/library_api.dart';
import '../../library/presentation/library_summary.dart';
import '../../node_fetch/data/node_fetch_api.dart';
import '../data/remote_search_api.dart';
import '../domain/remote_track.dart';

const String remoteImportAcceptedMessage =
    'La requête a été envoyée au serveur et est en cours de traitement en arrière-plan.';

enum RemoteImportPhase {
  idle,
  submitting,
  queued,
  fetching,
  readyForImport,
  monitoringPaused,
  failed,
}

class RemoteImportState {
  const RemoteImportState({
    this.phase = RemoteImportPhase.idle,
    this.message,
    this.jobId,
    this.filename,
    this.bytesReceived = 0,
  });

  final RemoteImportPhase phase;
  final String? message;
  final String? jobId;
  final String? filename;
  final int bytesReceived;

  bool get isActive => switch (phase) {
    RemoteImportPhase.submitting ||
    RemoteImportPhase.queued ||
    RemoteImportPhase.fetching => true,
    _ => false,
  };
}

class RemoteSearchState {
  const RemoteSearchState({
    this.query = '',
    this.results = const [],
    this.imports = const {},
    this.loading = false,
    this.searched = false,
    this.error,
  });

  final String query;
  final List<RemoteTrack> results;
  final Map<String, RemoteImportState> imports;
  final bool loading;
  final bool searched;
  final String? error;

  RemoteSearchState copyWith({
    String? query,
    List<RemoteTrack>? results,
    Map<String, RemoteImportState>? imports,
    bool? loading,
    bool? searched,
    String? error,
    bool clearError = false,
  }) {
    return RemoteSearchState(
      query: query ?? this.query,
      results: results ?? this.results,
      imports: imports ?? this.imports,
      loading: loading ?? this.loading,
      searched: searched ?? this.searched,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

final remoteImportPollIntervalProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 1),
);

final remoteImportMaxPollAttemptsProvider = Provider<int>((ref) => 720);

final remoteImportLibraryRefreshDelaysProvider = Provider<List<Duration>>(
  (ref) => const [Duration.zero, Duration(seconds: 3), Duration(seconds: 8)],
);

class RemoteSearchController extends Notifier<RemoteSearchState> {
  int _searchSequence = 0;
  bool _disposed = false;
  final Map<String, int> _importGenerations = {};

  RemoteSearchRepository get _api => ref.read(remoteSearchApiProvider);

  @override
  RemoteSearchState build() {
    ref.onDispose(() {
      _disposed = true;
      _searchSequence += 1;
      _importGenerations.clear();
    });
    return const RemoteSearchState();
  }

  Future<void> search(String rawQuery) async {
    final query = rawQuery.trim();
    if (query.length < 2 || query.length > 200) {
      state = state.copyWith(
        query: query,
        results: const [],
        loading: false,
        searched: true,
        error: 'La recherche doit contenir entre 2 et 200 caractères.',
      );
      return;
    }
    final sequence = ++_searchSequence;
    state = state.copyWith(
      query: query,
      results: const [],
      loading: true,
      searched: false,
      clearError: true,
    );
    try {
      final results = await _api.search(query);
      if (_disposed || sequence != _searchSequence || !ref.mounted) return;
      state = state.copyWith(
        results: results,
        loading: false,
        searched: true,
        clearError: true,
      );
    } on RemoteSearchApiException catch (error) {
      if (_disposed || sequence != _searchSequence || !ref.mounted) return;
      state = state.copyWith(
        results: const [],
        loading: false,
        searched: true,
        error: error.message,
      );
    }
  }

  Future<void> importTrack(String trackId) async {
    if (state.imports[trackId]?.isActive ?? false) return;
    final generation = (_importGenerations[trackId] ?? 0) + 1;
    _importGenerations[trackId] = generation;
    _setImport(
      trackId,
      const RemoteImportState(
        phase: RemoteImportPhase.submitting,
        message: 'Envoi de la demande d’import…',
      ),
    );
    try {
      final job = await _api.importTrack(trackId);
      if (!_isCurrent(trackId, generation)) return;
      _setImport(
        trackId,
        RemoteImportState(
          phase: RemoteImportPhase.queued,
          message: remoteImportAcceptedMessage,
          jobId: job.id,
        ),
      );
      unawaited(_poll(trackId, job.id, generation));
    } on RemoteSearchApiException catch (error) {
      if (!_isCurrent(trackId, generation)) return;
      _setImport(
        trackId,
        RemoteImportState(
          phase: RemoteImportPhase.failed,
          message: error.message,
        ),
      );
    }
  }

  Future<void> resumeMonitoring(String trackId) async {
    final current = state.imports[trackId];
    final jobId = current?.jobId;
    if (jobId == null || jobId.isEmpty) return;
    final generation = (_importGenerations[trackId] ?? 0) + 1;
    _importGenerations[trackId] = generation;
    _setImport(
      trackId,
      RemoteImportState(
        phase: RemoteImportPhase.fetching,
        message: 'Reprise du suivi de l’import…',
        jobId: jobId,
        filename: current?.filename,
        bytesReceived: current?.bytesReceived ?? 0,
      ),
    );
    await _poll(trackId, jobId, generation);
  }

  Future<void> _poll(String trackId, String jobId, int generation) async {
    final interval = ref.read(remoteImportPollIntervalProvider);
    final maxAttempts = ref.read(remoteImportMaxPollAttemptsProvider);
    var consecutiveErrors = 0;
    for (var attempt = 0; attempt < maxAttempts; attempt += 1) {
      await Future<void>.delayed(interval);
      if (!_isCurrent(trackId, generation)) return;
      try {
        final job = await _api.fetchImportJob(jobId);
        if (!_isCurrent(trackId, generation)) return;
        consecutiveErrors = 0;
        if (_applyJob(trackId, job, generation)) return;
      } on RemoteSearchApiException {
        consecutiveErrors += 1;
        if (consecutiveErrors >= 3) {
          _setImport(
            trackId,
            RemoteImportState(
              phase: RemoteImportPhase.monitoringPaused,
              message:
                  'Le suivi réseau est interrompu, mais le traitement serveur peut continuer.',
              jobId: jobId,
            ),
          );
          return;
        }
      }
    }
    if (_isCurrent(trackId, generation)) {
      _setImport(
        trackId,
        RemoteImportState(
          phase: RemoteImportPhase.monitoringPaused,
          message: 'Le traitement continue en arrière-plan.',
          jobId: jobId,
        ),
      );
    }
  }

  bool _applyJob(String trackId, NodeFetchJob job, int generation) {
    switch (job.status) {
      case NodeFetchJobStatus.queued:
        _setImport(
          trackId,
          RemoteImportState(
            phase: RemoteImportPhase.queued,
            message: remoteImportAcceptedMessage,
            jobId: job.id,
          ),
        );
        return false;
      case NodeFetchJobStatus.fetching:
        _setImport(
          trackId,
          RemoteImportState(
            phase: RemoteImportPhase.fetching,
            message: 'Le serveur récupère le FLAC vers ton inbox…',
            jobId: job.id,
            bytesReceived: job.bytesReceived,
          ),
        );
        return false;
      case NodeFetchJobStatus.readyForImport:
        _setImport(
          trackId,
          RemoteImportState(
            phase: RemoteImportPhase.readyForImport,
            message:
                'Le fichier est dans l’inbox. Le watcher termine son import.',
            jobId: job.id,
            filename: job.filename,
            bytesReceived: job.bytesReceived,
          ),
        );
        unawaited(_refreshLibrary(trackId, generation));
        return true;
      case NodeFetchJobStatus.failed:
        _setImport(
          trackId,
          RemoteImportState(
            phase: RemoteImportPhase.failed,
            message: job.errorMessage ?? 'L’import distant a échoué.',
            jobId: job.id,
          ),
        );
        return true;
    }
  }

  Future<void> _refreshLibrary(String trackId, int generation) async {
    for (final delay in ref.read(remoteImportLibraryRefreshDelaysProvider)) {
      await Future<void>.delayed(delay);
      if (!_isCurrent(trackId, generation)) return;
      ref.invalidate(libraryProvider);
      ref.invalidate(userLibrarySummaryProvider);
    }
  }

  bool _isCurrent(String trackId, int generation) {
    return !_disposed &&
        ref.mounted &&
        _importGenerations[trackId] == generation;
  }

  void _setImport(String trackId, RemoteImportState importState) {
    if (_disposed || !ref.mounted) return;
    state = state.copyWith(
      imports: <String, RemoteImportState>{
        ...state.imports,
        trackId: importState,
      },
    );
  }
}

final remoteSearchControllerProvider =
    NotifierProvider<RemoteSearchController, RemoteSearchState>(
      RemoteSearchController.new,
      name: 'remoteSearch',
    );
