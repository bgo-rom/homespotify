import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../domain/offline_models.dart';

/// Erreur hors ligne présentable (message court, sans stack Dio).
class OfflineApiException implements Exception {
  OfflineApiException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}

/// Contrats hors ligne Phase 1A (interface : les tests injectent un fake).
abstract interface class OfflineApi {
  Future<List<OfflineOption>> fetchOptions(int trackId);
  Future<OfflineVariantState> requestVariant(
    int trackId,
    OfflineProfile profile, {
    CancelToken? cancelToken,
  });
  Future<OfflineVariantState> variantStatus(
    int trackId,
    OfflineProfile profile, {
    CancelToken? cancelToken,
  });
  Uri downloadUri(int trackId, OfflineProfile profile);
  Future<Response<ResponseBody>> openDownloadStream(
    int trackId,
    OfflineProfile profile, {
    int fromByte,
    CancelToken? cancelToken,
  });
}

/// Implémentation HTTP réelle. Toutes les requêtes passent par le Dio partagé
/// (Bearer injecté par AuthInterceptor — jamais de token stocké ici).
class HttpOfflineApi implements OfflineApi {
  HttpOfflineApi(this._dio, this._baseUrl);

  final Dio _dio;
  final String _baseUrl;

  @override
  Future<List<OfflineOption>> fetchOptions(int trackId) async {
    final res = await _get('/api/tracks/$trackId/offline-options');
    final options = (res['options'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(OfflineOption.fromJson)
        .toList(growable: false);
    if (options.isEmpty) {
      throw OfflineApiException('Aucune option hors ligne pour cette piste.');
    }
    return options;
  }

  /// Crée (ou retrouve, single-flight côté serveur) la variante Opus.
  /// 202 = encodage en cours, 200 = déjà prête.
  @override
  Future<OfflineVariantState> requestVariant(
    int trackId,
    OfflineProfile profile, {
    CancelToken? cancelToken,
  }) async {
    assert(profile != OfflineProfile.original, 'original ne se demande pas');
    final res = await _dio.post<Map<String, dynamic>>(
      '/api/tracks/$trackId/offline-variants/${profile.wire}',
      cancelToken: cancelToken,
    );
    return _variantFromResponse(res);
  }

  @override
  Future<OfflineVariantState> variantStatus(
    int trackId,
    OfflineProfile profile, {
    CancelToken? cancelToken,
  }) async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/api/tracks/$trackId/offline-variants/${profile.wire}',
      cancelToken: cancelToken,
    );
    return _variantFromResponse(res);
  }

  /// URL de téléchargement : route Range canonique pour l'original, fichier de
  /// variante pour les Opus. Jamais de token dans l'URL.
  @override
  Uri downloadUri(int trackId, OfflineProfile profile) =>
      profile == OfflineProfile.original
      ? Uri.parse('$_baseUrl/api/tracks/$trackId/download')
      : Uri.parse(
          '$_baseUrl/api/tracks/$trackId/offline-variants/${profile.wire}/file',
        );

  /// Ouvre le flux de téléchargement, éventuellement repris à `fromByte`.
  /// L'appelant lit `response.data.stream` et gère 200/206/404/416 lui-même.
  @override
  Future<Response<ResponseBody>> openDownloadStream(
    int trackId,
    OfflineProfile profile, {
    int fromByte = 0,
    CancelToken? cancelToken,
  }) {
    return _dio.get<ResponseBody>(
      downloadUri(trackId, profile).toString(),
      options: Options(
        responseType: ResponseType.stream,
        headers: fromByte > 0 ? {'range': 'bytes=$fromByte-'} : null,
        // Un 416 (reprise au-delà de la fin) doit remonter comme réponse, pas
        // comme exception : validateStatus < 500 est déjà le défaut du client.
      ),
      cancelToken: cancelToken,
    );
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final Response<Map<String, dynamic>> res;
    try {
      res = await _dio.get<Map<String, dynamic>>(path);
    } on DioException catch (error) {
      throw OfflineApiException(_friendlyDioMessage(error));
    }
    final data = res.data;
    if (res.statusCode != 200 || data == null) {
      throw OfflineApiException(
        _messageFromBody(res.data, res.statusCode),
        statusCode: res.statusCode,
      );
    }
    return data;
  }

  OfflineVariantState _variantFromResponse(Response<Map<String, dynamic>> res) {
    final status = res.statusCode ?? 0;
    final data = res.data;
    if ((status == 200 || status == 202) && data != null) {
      return OfflineVariantState.fromJson(data);
    }
    throw OfflineApiException(
      _messageFromBody(data, status),
      statusCode: status,
    );
  }

  String _messageFromBody(dynamic data, int? statusCode) {
    if (data is Map && data['message'] is String) {
      return data['message'] as String;
    }
    return 'Réponse invalide du serveur (${statusCode ?? '?'}).';
  }

  String _friendlyDioMessage(DioException error) => switch (error.type) {
    DioExceptionType.connectionError ||
    DioExceptionType.connectionTimeout => 'Serveur injoignable.',
    DioExceptionType.receiveTimeout ||
    DioExceptionType.sendTimeout => 'Le serveur met trop de temps à répondre.',
    _ => 'Échec de la requête hors ligne (${error.type.name}).',
  };
}

final offlineApiProvider = Provider<OfflineApi>((ref) {
  return HttpOfflineApi(ref.watch(apiClientProvider), homespotifyApiBaseUrl);
});
