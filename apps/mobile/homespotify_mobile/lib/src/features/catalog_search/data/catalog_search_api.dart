import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../domain/catalog_models.dart';

/// Erreur présentable de la recherche catalogue.
class CatalogSearchException implements Exception {
  const CatalogSearchException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => message;
}

abstract interface class CatalogSearchRepository {
  Future<CatalogSearchPage> search({
    required String query,
    required CatalogEntityType type,
    String? cursor,
    int limit,
  });

  Future<CatalogArtistDetail> fetchArtist(CatalogEntityRef reference);
  Future<CatalogAlbumPage> fetchArtistAlbums(
    CatalogEntityRef reference, {
    String? cursor,
  });
  Future<CatalogAlbumDetail> fetchAlbum(CatalogEntityRef reference);
  Future<List<ProviderStatus>> fetchProviders();
}

/// Accès backend /api/discovery/*. Le Bearer HomeSpotify est porté par
/// l'intercepteur du Dio partagé et ne sort JAMAIS vers un domaine externe.
/// Aucun secret fournisseur ne transite ici (tout vit côté serveur).
class CatalogSearchApi implements CatalogSearchRepository {
  CatalogSearchApi(this._dio);

  final Dio _dio;

  @override
  Future<CatalogSearchPage> search({
    required String query,
    required CatalogEntityType type,
    String? cursor,
    int limit = 20,
  }) async {
    final response = await _request(
      () => _dio.get<Map<String, dynamic>>(
        '/api/discovery/search',
        queryParameters: {
          'q': query,
          'type': type.wireName,
          'limit': limit,
          'cursor': ?cursor,
        },
      ),
    );
    return CatalogSearchPage.fromJson(response.data ?? const {});
  }

  @override
  Future<CatalogArtistDetail> fetchArtist(CatalogEntityRef reference) async {
    final response = await _request(
      () => _dio.get<Map<String, dynamic>>(
        '/api/discovery/artists/${reference.provider}/${reference.externalId}',
      ),
    );
    return CatalogArtistDetail.fromJson(response.data ?? const {});
  }

  @override
  Future<CatalogAlbumPage> fetchArtistAlbums(
    CatalogEntityRef reference, {
    String? cursor,
  }) async {
    final response = await _request(
      () => _dio.get<Map<String, dynamic>>(
        '/api/discovery/artists/${reference.provider}/${reference.externalId}/albums',
        queryParameters: {'cursor': ?cursor},
      ),
    );
    return CatalogAlbumPage.fromJson(response.data ?? const {});
  }

  @override
  Future<CatalogAlbumDetail> fetchAlbum(CatalogEntityRef reference) async {
    final response = await _request(
      () => _dio.get<Map<String, dynamic>>(
        '/api/discovery/albums/${reference.provider}/${reference.externalId}',
      ),
    );
    return CatalogAlbumDetail.fromJson(response.data ?? const {});
  }

  @override
  Future<List<ProviderStatus>> fetchProviders() async {
    final response = await _request(
      () => _dio.get<Map<String, dynamic>>('/api/discovery/providers'),
    );
    return (response.data?['providers'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(
          (json) => ProviderStatus(
            id: json['id'] as String? ?? '',
            status: (json['enabled'] as bool? ?? false) ? 'OK' : 'DISABLED',
            message: json['disabledReason'] as String?,
          ),
        )
        .toList(growable: false);
  }

  Future<Response<T>> _request<T>(
    Future<Response<T>> Function() request,
  ) async {
    try {
      return await request();
    } on DioException catch (error) {
      throw CatalogSearchException(
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
      DioExceptionType.receiveTimeout ||
      DioExceptionType.sendTimeout => 'Le serveur met trop de temps à répondre.',
      _ => 'Échec de la recherche catalogue.',
    };
  }
}

final catalogSearchApiProvider = Provider<CatalogSearchRepository>((ref) {
  return CatalogSearchApi(ref.watch(apiClientProvider));
});
