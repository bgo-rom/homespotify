import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../domain/discovery_models.dart';

/// Erreur découverte/demandes présentable à l'utilisateur.
class DiscoveryApiException implements Exception {
  const DiscoveryApiException(this.message, {this.code});

  final String message;

  /// Code stable renvoyé par le backend (`already_owned`, …), si disponible.
  final String? code;

  @override
  String toString() => message;
}

class MusicRequestDraftItem {
  const MusicRequestDraftItem({
    required this.title,
    this.artist,
    this.album,
    this.durationMs,
    this.isrc,
  });

  final String title;
  final String? artist;
  final String? album;

  /// Snapshot catalogue : durée et ISRC quand la source les fournit.
  final int? durationMs;
  final String? isrc;

  Map<String, dynamic> toJson(int position) => {
    'position': position,
    'title': title,
    'artist': ?artist,
    'album': ?album,
    'durationMs': ?durationMs,
    'isrc': ?isrc,
  };
}

class MusicRequestDraft {
  const MusicRequestDraft({
    required this.requestType,
    required this.title,
    this.artist,
    this.album,
    this.externalUrl,
    this.coverUrl,
    this.userNote,
    this.items = const [],
  });

  final MusicRequestType requestType;
  final String title;
  final String? artist;
  final String? album;
  final String? externalUrl;
  final String? coverUrl;
  final String? userNote;
  final List<MusicRequestDraftItem> items;

  Map<String, dynamic> toJson() => {
    'requestType': requestType.wireName,
    'title': title,
    'artist': ?artist,
    'album': ?album,
    'externalUrl': ?externalUrl,
    'coverUrl': ?coverUrl,
    'userNote': ?userNote,
    'items': [
      for (var index = 0; index < items.length; index += 1)
        items[index].toJson(index + 1),
    ],
  };
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
  Future<MusicRequest> createRequest(int candidateId);
  Future<MusicRequest> createCustomRequest(MusicRequestDraft draft);
  Future<List<MusicRequest>> fetchRequests();
  Future<MusicRequest> cancelRequest(int requestId);
}

/// Accès backend découverte + demandes. Le userId n'est JAMAIS envoyé : il
/// vient du token porté par l'intercepteur du Dio partagé. Aucune de ces
/// méthodes ne déclenche de téléchargement.
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

  @override
  Future<MusicRequest> createRequest(int candidateId) async {
    final res = await _request<Map<String, dynamic>>(
      () => _dio.post<Map<String, dynamic>>(
        '/api/music-requests',
        data: {'candidateId': candidateId},
      ),
    );
    return MusicRequest.fromJson(res.data ?? const <String, dynamic>{});
  }

  @override
  Future<MusicRequest> createCustomRequest(MusicRequestDraft draft) async {
    final res = await _request<Map<String, dynamic>>(
      () => _dio.post<Map<String, dynamic>>(
        '/api/music-requests',
        data: draft.toJson(),
      ),
    );
    return MusicRequest.fromJson(res.data ?? const <String, dynamic>{});
  }

  @override
  Future<List<MusicRequest>> fetchRequests() async {
    final res = await _request<Map<String, dynamic>>(
      () => _dio.get<Map<String, dynamic>>('/api/music-requests'),
    );
    final items = res.data?['items'] as List<dynamic>? ?? const [];
    return items
        .whereType<Map<String, dynamic>>()
        .map(MusicRequest.fromJson)
        .toList(growable: false);
  }

  @override
  Future<MusicRequest> cancelRequest(int requestId) async {
    final res = await _request<Map<String, dynamic>>(
      () => _dio.post<Map<String, dynamic>>(
        '/api/music-requests/$requestId/cancel',
      ),
    );
    return MusicRequest.fromJson(res.data ?? const <String, dynamic>{});
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
