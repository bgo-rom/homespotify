import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../data/discovery_api.dart';
import '../domain/discovery_models.dart';

/// État du paquet de cartes « Découvrir ».
///
/// Vit dans un [Notifier] Riverpod (jamais dans l'état d'un widget) : le
/// paquet survit aux rebuilds et aux allers-retours de navigation.
class DiscoverDeckState {
  const DiscoverDeckState({
    this.deck = const [],
    this.loading = false,
    this.loadingMore = false,
    this.refreshing = false,
    this.busy = false,
    this.error,
    this.nextCursor,
    this.loadedOnce = false,
    this.status,
  });

  final List<RecommendationCandidate> deck;

  /// Chargement initial (affiche les skeletons).
  final bool loading;

  /// Chargement de la page suivante en arrière-plan.
  final bool loadingMore;

  /// Régénération serveur en cours (job asynchrone).
  final bool refreshing;

  /// Une action de swipe est en transit : verrouille les interactions.
  final bool busy;

  final String? error;
  final String? nextCursor;

  /// Au moins un chargement complet a abouti (évite les doubles auto-refresh).
  final bool loadedOnce;

  /// Dernier état de file connu (alimente l'écran de préparation : cartes
  /// prêtes, réserve, statut de génération). Null tant qu'inconnu.
  final RecommendationQueueStatus? status;

  DiscoverDeckState copyWith({
    List<RecommendationCandidate>? deck,
    bool? loading,
    bool? loadingMore,
    bool? refreshing,
    bool? busy,
    String? error,
    bool clearError = false,
    String? nextCursor,
    bool clearCursor = false,
    bool? loadedOnce,
    RecommendationQueueStatus? status,
  }) {
    return DiscoverDeckState(
      deck: deck ?? this.deck,
      loading: loading ?? this.loading,
      loadingMore: loadingMore ?? this.loadingMore,
      refreshing: refreshing ?? this.refreshing,
      busy: busy ?? this.busy,
      error: clearError ? null : (error ?? this.error),
      nextCursor: clearCursor ? null : (nextCursor ?? this.nextCursor),
      loadedOnce: loadedOnce ?? this.loadedOnce,
      status: status ?? this.status,
    );
  }

  RecommendationCandidate? get top => deck.isEmpty ? null : deck.first;
}

/// Seuil sous lequel la page suivante est préchargée.
const int _prefetchThreshold = 4;

class DiscoverDeckController extends Notifier<DiscoverDeckState> {
  DiscoveryRepository get _repository => ref.read(discoveryApiProvider);

  bool _autoRefreshAttempted = false;
  Timer? _pollTimer;
  Completer<bool>? _pollCompleter;

  /// Jeton de génération du sondage : incrémenté à chaque `refresh()` et à
  /// chaque `cancelRefresh()`. Une boucle dont le jeton a changé s'arrête
  /// (single-flight strict, aucune boucle orpheline).
  int _pollGeneration = 0;

  /// Dernier libellé de statut journalisé (ne loguer que les TRANSITIONS).
  String? _lastPollLabel;

  @override
  DiscoverDeckState build() {
    ref.onDispose(_cancelPolling);
    return const DiscoverDeckState();
  }

  /// Attente adaptative avant le prochain sondage (recule la cadence) :
  /// 1re vérif ~800 ms, quelques suivantes ~1500 ms, puis ~2800 ms.
  Duration _pollDelay(int attempt) {
    if (attempt <= 0) return const Duration(milliseconds: 800);
    if (attempt <= 3) return const Duration(milliseconds: 1500);
    return const Duration(milliseconds: 2800);
  }

  Future<bool> _waitForNextPoll(Duration delay) {
    _cancelPolling();
    final completer = Completer<bool>();
    _pollCompleter = completer;
    _pollTimer = Timer(delay, () {
      _pollTimer = null;
      _pollCompleter = null;
      if (!completer.isCompleted) completer.complete(true);
    });
    return completer.future;
  }

  void _cancelPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    final completer = _pollCompleter;
    _pollCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete(false);
  }

  /// Arrêt EXTERNE du sondage (sortie d'écran, app en pause/détachée, logout).
  /// Invalide la génération courante : la boucle en cours se termine proprement
  /// et l'état « refreshing » est levé.
  void cancelRefresh() {
    _pollGeneration += 1;
    _cancelPolling();
    if (state.refreshing) {
      state = state.copyWith(refreshing: false);
    }
  }

  /// Journalise UNIQUEMENT les transitions de statut (jamais chaque sonde).
  void _logStatusTransition(RecommendationQueueStatus status) {
    final label = status.pollLabel;
    if (label != _lastPollLabel) {
      logNetwork(
        'Recommendation refresh: ${_lastPollLabel ?? 'REFRESHING'} -> $label',
      );
      _lastPollLabel = label;
    }
  }

  /// Chargement initial : lecture instantanée de la file locale du serveur.
  /// Si la file est vide au premier passage, tente UNE régénération.
  Future<void> load() async {
    if (state.loading) return;
    state = state.copyWith(loading: true, clearError: true);
    try {
      final page = await _repository.fetchRecommendations();
      if (!ref.mounted) return;
      if (page.items.isEmpty && !_autoRefreshAttempted) {
        _autoRefreshAttempted = true;
        state = state.copyWith(loading: false, loadedOnce: true);
        await refresh();
        return;
      }
      state = state.copyWith(
        deck: page.items,
        loading: false,
        loadedOnce: true,
        nextCursor: page.nextCursor,
        clearCursor: page.nextCursor == null,
      );
    } on DiscoveryApiException catch (error) {
      if (!ref.mounted) return;
      state = state.copyWith(
        loading: false,
        loadedOnce: true,
        error: error.message,
      );
    }
  }

  /// Déclenche la régénération serveur (202) puis SONDE `/status` en cadence
  /// ADAPTATIVE jusqu'à un état TERMINAL (prêt, épuisé ou erreur), et recharge
  /// alors immédiatement le feed. Single-flight strict (jeton de génération) :
  /// aucun sondage parallèle ni boucle orpheline. Arrêt propre sur
  /// `cancelRefresh()` / démontage / navigation / pause.
  Future<void> refresh() async {
    if (state.refreshing) return;
    final generation = ++_pollGeneration;
    _lastPollLabel = null;
    state = state.copyWith(refreshing: true, clearError: true);
    try {
      await _repository.triggerRefresh();
      // Borne de sécurité : ~10 sondes max, mais on sort dès l'état terminal.
      for (var attempt = 0; attempt < 10; attempt += 1) {
        if (!await _waitForNextPoll(_pollDelay(attempt))) return; // annulé
        if (!ref.mounted || generation != _pollGeneration) return;
        final status = await _repository.fetchStatus();
        if (!ref.mounted || generation != _pollGeneration) return;
        _logStatusTransition(status);
        state = state.copyWith(status: status);
        if (status.isTerminal) break;
      }
      if (!ref.mounted || generation != _pollGeneration) return;
      final page = await _repository.fetchRecommendations();
      if (!ref.mounted || generation != _pollGeneration) return;
      state = state.copyWith(
        deck: page.items,
        refreshing: false,
        loadedOnce: true,
        nextCursor: page.nextCursor,
        clearCursor: page.nextCursor == null,
      );
    } on DiscoveryApiException catch (error) {
      if (!ref.mounted || generation != _pollGeneration) return;
      state = state.copyWith(refreshing: false, error: error.message);
    }
  }

  /// Précharge la page suivante quand le paquet devient court.
  Future<void> loadMoreIfNeeded() async {
    final cursor = state.nextCursor;
    if (cursor == null ||
        state.loadingMore ||
        state.deck.length > _prefetchThreshold) {
      return;
    }
    state = state.copyWith(loadingMore: true);
    try {
      final page = await _repository.fetchRecommendations(cursor: cursor);
      if (!ref.mounted) return;
      final known = state.deck.map((c) => c.id).toSet();
      state = state.copyWith(
        deck: [
          ...state.deck,
          ...page.items.where((c) => !known.contains(c.id)),
        ],
        loadingMore: false,
        nextCursor: page.nextCursor,
        clearCursor: page.nextCursor == null,
      );
    } on DiscoveryApiException catch (error) {
      if (!ref.mounted) return;
      // Le préchargement est opportuniste : on garde le paquet actuel.
      logError('préchargement recommandations échoué: ${error.message}');
      state = state.copyWith(loadingMore: false);
    }
  }

  /// Retire la carte du dessus (après une action réussie).
  void advance() {
    if (state.deck.isEmpty) return;
    state = state.copyWith(deck: state.deck.sublist(1));
    // Fire-and-forget : le préchargement ne bloque jamais le geste.
    loadMoreIfNeeded();
  }

  /// DISLIKE avec verrou anti double-soumission. Retourne true si accepté ;
  /// false = rollback visuel (la carte reste en place).
  Future<bool> dislike(RecommendationCandidate candidate) async {
    if (state.busy) return false;
    state = state.copyWith(busy: true);
    try {
      await _repository.sendAction(
        candidate.id,
        RecommendationSwipeAction.dislike,
      );
      logUi('swipe DISLIKE candidat=${candidate.id}');
      return true;
    } on DiscoveryApiException catch (error) {
      if (ref.mounted) state = state.copyWith(error: error.message);
      return false;
    } finally {
      if (ref.mounted) state = state.copyWith(busy: false);
    }
  }

  /// SKIP : signal faible, jamais bloquant.
  Future<void> skip(RecommendationCandidate candidate) async {
    if (state.busy) return;
    logUi('SKIP candidat=${candidate.id}');
    sendActionSilently(candidate.id, RecommendationSwipeAction.skip);
    advance();
  }

  /// Envoie la demande (le LIKE d'affinité part en parallèle). Retourne
  /// true si la carte doit être retirée du paquet.
  Future<bool> request(RecommendationCandidate candidate) async {
    if (state.busy) return false;
    state = state.copyWith(busy: true);
    try {
      sendActionSilently(candidate.id, RecommendationSwipeAction.like);
      await _repository.createRequest(candidate.id);
      logUi('demande envoyée candidat=${candidate.id}');
      return true;
    } on DiscoveryApiException catch (error) {
      if (ref.mounted) state = state.copyWith(error: error.message);
      // Doublon/déjà possédée : on retire quand même la carte du paquet.
      return error.code == 'duplicate_active_request' ||
          error.code == 'already_owned';
    } finally {
      if (ref.mounted) state = state.copyWith(busy: false);
    }
  }

  void sendActionSilently(int candidateId, RecommendationSwipeAction action) {
    _repository.sendAction(candidateId, action).catchError((Object error) {
      logError('action ${action.wireName} non enregistrée', error: error);
    });
  }

  /// Consomme l'erreur courante (affichée une seule fois en snackbar).
  String? takeError() {
    final message = state.error;
    if (message != null) state = state.copyWith(clearError: true);
    return message;
  }
}

final discoverDeckProvider =
    NotifierProvider<DiscoverDeckController, DiscoverDeckState>(
      DiscoverDeckController.new,
      name: 'discoverDeck',
    );
