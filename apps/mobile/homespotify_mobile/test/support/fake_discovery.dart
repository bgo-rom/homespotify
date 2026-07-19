import 'package:homespotify_mobile/src/features/discovery/data/discovery_api.dart';
import 'package:homespotify_mobile/src/features/discovery/domain/discovery_models.dart';

/// Fake en mémoire du dépôt découverte/demandes pour les tests widgets.
class FakeDiscoveryRepository implements DiscoveryRepository {
  FakeDiscoveryRepository({
    List<RecommendationCandidate> recommendations = const [],
    List<MusicRequest> requests = const [],
    this.pageSize = 15,
    this.fetchDelay,
    this.statusRefreshing = false,
    this.refreshingPolls = 0,
  }) : recommendations = List.of(recommendations),
       requests = List.of(requests);

  List<RecommendationCandidate> recommendations;
  List<MusicRequest> requests;
  final int pageSize;

  /// Latence artificielle du fetch (test des skeletons).
  final Duration? fetchDelay;
  bool statusRefreshing;

  /// Nombre de sondes `/status` qui renvoient `refreshing: true` avant d'arriver
  /// à un état terminal (test du sondage adaptatif). 0 = terminal immédiat.
  final int refreshingPolls;

  final List<(int, RecommendationSwipeAction)> actions = [];
  final List<int> createdRequests = [];
  final List<MusicRequestDraft> customRequests = [];
  final List<int> cancelledRequests = [];
  int refreshCount = 0;
  int fetchCount = 0;

  /// Nombre d'appels à `fetchStatus` (vérifie l'arrêt du sondage au terminal).
  int statusCalls = 0;

  /// Si non null, la prochaine création de demande échoue avec ce code.
  DiscoveryApiException? nextCreateError;

  /// Si non null, la prochaine action de swipe échoue (test de rollback).
  DiscoveryApiException? nextActionError;

  @override
  Future<RecommendationPage> fetchRecommendations({
    String? cursor,
    int? limit,
  }) async {
    fetchCount += 1;
    final delay = fetchDelay;
    if (delay != null) await Future<void>.delayed(delay);
    final size = limit ?? pageSize;
    final offset = int.tryParse(cursor ?? '') ?? 0;
    final slice = recommendations.skip(offset).take(size).toList();
    final end = offset + slice.length;
    return RecommendationPage(
      items: slice,
      nextCursor: end < recommendations.length && slice.length == size
          ? '$end'
          : null,
    );
  }

  @override
  Future<String> triggerRefresh() async {
    refreshCount += 1;
    return 'started';
  }

  @override
  Future<RecommendationQueueStatus> fetchStatus() async {
    statusCalls += 1;
    final stillRefreshing = statusCalls <= refreshingPolls || statusRefreshing;
    return RecommendationQueueStatus(
      queueSize: recommendations.length,
      refreshing: stillRefreshing,
      generationStatus: stillRefreshing
          ? RecommendationGenerationStatus.refreshing
          : RecommendationGenerationStatus.ready,
    );
  }

  @override
  Future<void> sendAction(
    int candidateId,
    RecommendationSwipeAction action,
  ) async {
    final error = nextActionError;
    if (error != null) {
      nextActionError = null;
      throw error;
    }
    actions.add((candidateId, action));
  }

  @override
  Future<MusicRequest> createRequest(int candidateId) async {
    final error = nextCreateError;
    if (error != null) {
      nextCreateError = null;
      throw error;
    }
    createdRequests.add(candidateId);
    final request = MusicRequest(
      id: 100 + createdRequests.length,
      candidateId: candidateId,
      title: 'Titre $candidateId',
      artist: 'Artiste',
      status: MusicRequestStatus.sent,
    );
    requests = [request, ...requests];
    return request;
  }

  @override
  Future<MusicRequest> createCustomRequest(MusicRequestDraft draft) async {
    customRequests.add(draft);
    final request = MusicRequest(
      id: 200 + customRequests.length,
      candidateId: 0,
      title: draft.title,
      artist: draft.artist ?? '',
      album: draft.album,
      requestType: draft.requestType,
      status: MusicRequestStatus.sent,
      requestedItemCount: draft.items.length,
    );
    requests = [request, ...requests];
    return request;
  }

  @override
  Future<List<MusicRequest>> fetchRequests() async => List.of(requests);

  @override
  Future<MusicRequest> cancelRequest(int requestId) async {
    cancelledRequests.add(requestId);
    final existing = requests.firstWhere((r) => r.id == requestId);
    final updated = MusicRequest(
      id: existing.id,
      candidateId: existing.candidateId,
      title: existing.title,
      artist: existing.artist,
      album: existing.album,
      artworkUrl: existing.artworkUrl,
      status: MusicRequestStatus.cancelled,
      ownerNote: existing.ownerNote,
    );
    requests = [for (final r in requests) r.id == requestId ? updated : r];
    return updated;
  }
}
