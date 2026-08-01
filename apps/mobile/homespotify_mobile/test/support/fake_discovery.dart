import 'package:homespotify_mobile/src/features/discovery/data/discovery_api.dart';
import 'package:homespotify_mobile/src/features/discovery/domain/discovery_models.dart';

/// Fake en mémoire du dépôt découverte pour les tests widgets.
class FakeDiscoveryRepository implements DiscoveryRepository {
  FakeDiscoveryRepository({
    List<RecommendationCandidate> recommendations = const [],
    this.pageSize = 15,
    this.fetchDelay,
    this.statusRefreshing = false,
    this.refreshingPolls = 0,
  }) : recommendations = List.of(recommendations);

  List<RecommendationCandidate> recommendations;
  final int pageSize;

  /// Latence artificielle du fetch (test des skeletons).
  final Duration? fetchDelay;
  bool statusRefreshing;

  /// Nombre de sondes `/status` qui renvoient `refreshing: true` avant d'arriver
  /// à un état terminal (test du sondage adaptatif). 0 = terminal immédiat.
  final int refreshingPolls;

  final List<(int, RecommendationSwipeAction)> actions = [];
  int refreshCount = 0;
  int fetchCount = 0;

  /// Nombre d'appels à `fetchStatus` (vérifie l'arrêt du sondage au terminal).
  int statusCalls = 0;

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
}
