import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../domain/discovery_models.dart';

/// Erreur découverte présentable à l'utilisateur.
class DiscoveryApiException implements Exception {
  const DiscoveryApiException(this.message, {this.code});

  final String message;

  /// Code stable renvoyé par le backend (`already_owned`, …), si disponible.
  final String? code;

  @override
  String toString() => message;
}

abstract interface class DiscoveryRepository {
  /// Lit une page de la file pré-calculée locale au serveur (rapide). La file
  /// ne contient que des cartes MEDIA_READY (extrait + pochette garantis).
  Future<RecommendationPage> fetchRecommendations({String? cursor, int? limit});

  /// Déclenche la régénération ASYNCHRONE côté serveur (202).
  /// Retourne `started` ou `already_running`.
  Future<String> triggerRefresh();

  /// État de la file (taille, job en cours) pour piloter l'UI.
  Future<RecommendationQueueStatus> fetchStatus();

  Future<void> sendAction(int candidateId, RecommendationSwipeAction action);
}

/// Accès backend découverte. Le userId n'est JAMAIS envoyé : il vient du token
/// porté par l'intercepteur du Dio partagé. Aucune de ces méthodes ne crée de
/// demande : l'installation passe par `/api/downloads/search`.
class DiscoveryApi implements DiscoveryRepository {
  DiscoveryApi(this._dio);

  final Dio _dio;

  @override
  Future<RecommendationPage> fetchRecommendations({
    String? cursor,
    int? limit,
  }) async {
    final res = await _request<Map<String, dynamic>>(
      () => _dio.get<Map<String, dynamic>>(
        '/api/recommendations',
        queryParameters: {'cursor': ?cursor, 'limit': ?limit},
      ),
    );
    return RecommendationPage.fromJson(res.data ?? const <String, dynamic>{});
  }

  @override
  Future<String> triggerRefresh() async {
    final res = await _request<Map<String, dynamic>>(
      () => _dio.post<Map<String, dynamic>>('/api/recommendations/refresh'),
    );
    return res.data?['status'] as String? ?? 'started';
  }

  @override
  Future<RecommendationQueueStatus> fetchStatus() async {
    final res = await _request<Map<String, dynamic>>(
      () => _dio.get<Map<String, dynamic>>('/api/recommendations/status'),
    );
    return RecommendationQueueStatus.fromJson(
      res.data ?? const <String, dynamic>{},
    );
  }

  @override
  Future<void> sendAction(
    int candidateId,
    RecommendationSwipeAction action,
  ) async {
    await _request<Map<String, dynamic>>(
      () => _dio.post<Map<String, dynamic>>(
        '/api/recommendations/$candidateId/action',
        data: {'action': action.wireName},
      ),
    );
  }

  Future<Response<T>> _request<T>(
    Future<Response<T>> Function() request,
  ) async {
    try {
      return await request();
    } on DioException catch (error) {
      throw DiscoveryApiException(
        _messageForDio(error),
        code: _codeForDio(error),
      );
    }
  }

  String? _codeForDio(DioException error) {
    final data = error.response?.data;
    if (data is Map<String, dynamic> && data['error'] is String) {
      return data['error'] as String;
    }
    return null;
  }

  String _messageForDio(DioException error) {
    final data = error.response?.data;
    if (data is Map<String, dynamic>) {
      final message = data['message'];
      if (message is String && message.trim().isNotEmpty) return message;
    }
    return switch (error.type) {
      DioExceptionType.connectionError ||
      DioExceptionType.connectionTimeout => AppConfig.serverUnreachableMessage,
      DioExceptionType.receiveTimeout || DioExceptionType.sendTimeout =>
        'Le serveur met trop de temps à répondre.',
      _ => 'Échec de la communication avec le serveur.',
    };
  }
}

final discoveryApiProvider = Provider<DiscoveryRepository>((ref) {
  return DiscoveryApi(ref.watch(apiClientProvider));
});
