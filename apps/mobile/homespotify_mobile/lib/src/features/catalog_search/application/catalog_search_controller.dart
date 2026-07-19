import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../data/catalog_search_api.dart';
import '../domain/catalog_models.dart';

/// Debounce de saisie : aucune requête tant que l'utilisateur tape.
const Duration kCatalogSearchDebounce = Duration(milliseconds: 450);

/// Longueur minimale d'une recherche (aligné sur le backend).
const int kCatalogSearchMinLength = 2;

class CatalogSearchState {
  const CatalogSearchState({
    this.query = '',
    this.type = CatalogEntityType.track,
    this.results = const [],
    this.providers = const [],
    this.nextCursor,
    this.loading = false,
    this.loadingMore = false,
    this.error,
    this.partialResults = false,
    this.searched = false,
  });

  final String query;
  final CatalogEntityType type;
  final List<CatalogResult> results;
  final List<ProviderStatus> providers;
  final String? nextCursor;
  final bool loading;
  final bool loadingMore;
  final String? error;

  /// Au moins un provider a échoué mais des résultats partiels existent.
  final bool partialResults;

  /// Une recherche a réellement été exécutée (distingue l'état initial de
  /// l'état vide).
  final bool searched;

  bool get isQueryTooShort =>
      query.trim().isNotEmpty && query.trim().length < kCatalogSearchMinLength;

  CatalogSearchState copyWith({
    String? query,
    CatalogEntityType? type,
    List<CatalogResult>? results,
    List<ProviderStatus>? providers,
    String? nextCursor,
    bool clearCursor = false,
    bool? loading,
    bool? loadingMore,
    String? error,
    bool clearError = false,
    bool? partialResults,
    bool? searched,
  }) {
    return CatalogSearchState(
      query: query ?? this.query,
      type: type ?? this.type,
      results: results ?? this.results,
      providers: providers ?? this.providers,
      nextCursor: clearCursor ? null : (nextCursor ?? this.nextCursor),
      loading: loading ?? this.loading,
      loadingMore: loadingMore ?? this.loadingMore,
      error: clearError ? null : (error ?? this.error),
      partialResults: partialResults ?? this.partialResults,
      searched: searched ?? this.searched,
    );
  }
}

/// Contrôleur de la recherche catalogue : debounce, annulation LOGIQUE des
/// anciennes réponses (numéro de séquence — une réponse périmée est ignorée),
/// pagination par curseur opaque et résultats partiels tolérés.
class CatalogSearchController extends Notifier<CatalogSearchState> {
  Timer? _debounce;
  int _sequence = 0;

  @override
  CatalogSearchState build() {
    ref.onDispose(() {
      _debounce?.cancel();
      _debounce = null;
    });
    return const CatalogSearchState();
  }

  /// Saisie utilisateur : arme le debounce (450 ms).
  void onQueryChanged(String raw) {
    _debounce?.cancel();
    final query = raw;
    state = state.copyWith(query: query, clearError: true);
    final clean = query.trim();
    if (clean.length < kCatalogSearchMinLength) {
      _sequence += 1; // invalide toute réponse en vol
      state = state.copyWith(
        results: const [],
        loading: false,
        searched: false,
        clearCursor: true,
        partialResults: false,
      );
      return;
    }
    _debounce = Timer(kCatalogSearchDebounce, () => _runSearch());
  }

  /// Changement d'onglet : recherche immédiate avec le même texte.
  void onTypeChanged(CatalogEntityType type) {
    if (type == state.type) return;
    _debounce?.cancel();
    state = state.copyWith(
      type: type,
      results: const [],
      clearCursor: true,
      partialResults: false,
      clearError: true,
    );
    if (state.query.trim().length >= kCatalogSearchMinLength) {
      _runSearch();
    }
  }

  /// Relance manuelle (bouton Réessayer / pull-to-refresh).
  Future<void> retry() => _runSearch();

  Future<void> _runSearch() async {
    final query = state.query.trim();
    if (query.length < kCatalogSearchMinLength) return;
    final sequence = ++_sequence;
    state = state.copyWith(loading: true, clearError: true, clearCursor: true);
    try {
      final page = await ref
          .read(catalogSearchApiProvider)
          .search(query: query, type: state.type);
      if (sequence != _sequence || !ref.mounted) return; // réponse périmée
      state = state.copyWith(
        results: page.items,
        providers: page.providers,
        nextCursor: page.nextCursor,
        loading: false,
        searched: true,
        partialResults: page.hasDegradedProvider && page.items.isNotEmpty,
        error: page.hasDegradedProvider && page.items.isEmpty
            ? 'Certains fournisseurs sont indisponibles.'
            : null,
      );
    } on CatalogSearchException catch (error) {
      if (sequence != _sequence || !ref.mounted) return;
      logError('recherche catalogue échouée', error: error);
      state = state.copyWith(
        loading: false,
        searched: true,
        results: const [],
        error: error.message,
      );
    }
  }

  /// Page suivante : ajoute à la liste (jamais de doublon de canonicalKey).
  Future<void> loadMore() async {
    final cursor = state.nextCursor;
    final query = state.query.trim();
    if (cursor == null || state.loadingMore || state.loading) return;
    if (query.length < kCatalogSearchMinLength) return;
    final sequence = _sequence;
    state = state.copyWith(loadingMore: true);
    try {
      final page = await ref
          .read(catalogSearchApiProvider)
          .search(query: query, type: state.type, cursor: cursor);
      if (sequence != _sequence || !ref.mounted) return;
      final known = state.results
          .map((result) => result.canonicalKey)
          .toSet();
      state = state.copyWith(
        results: [
          ...state.results,
          ...page.items.where(
            (item) =>
                item.canonicalKey.isEmpty ||
                !known.contains(item.canonicalKey),
          ),
        ],
        nextCursor: page.nextCursor,
        clearCursor: page.nextCursor == null,
        loadingMore: false,
      );
    } on CatalogSearchException {
      if (sequence != _sequence || !ref.mounted) return;
      state = state.copyWith(loadingMore: false);
    }
  }
}

final catalogSearchProvider =
    NotifierProvider<CatalogSearchController, CatalogSearchState>(
      CatalogSearchController.new,
      name: 'catalogSearch',
    );
