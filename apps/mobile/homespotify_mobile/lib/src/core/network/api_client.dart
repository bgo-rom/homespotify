import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_config.dart';

/// Alias conservé pour les appels existants ; la source de vérité est
/// [AppConfig.apiBaseUrl] (configurable par --dart-define uniquement).
const String homespotifyApiBaseUrl = AppConfig.apiBaseUrl;

final Dio apiClient = createApiClient();

final apiClientProvider = Provider<Dio>((ref) => apiClient);

Dio createApiClient({String baseUrl = homespotifyApiBaseUrl}) {
  final dio = Dio(
    BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 30),
      responseType: ResponseType.json,
      receiveDataWhenStatusError: true,
      headers: const {Headers.acceptHeader: Headers.jsonContentType},
      validateStatus: (status) => status != null && status < 500,
    ),
  );

  if (kDebugMode) {
    dio.interceptors.add(_DebugLogInterceptor());
  }

  return dio;
}

class _DebugLogInterceptor extends Interceptor {
  /// Endpoint sondé en boucle par la préparation des recommandations : ses
  /// appels RÉUSSIS sont TROP bruyants. On ne les journalise pas ici — les
  /// TRANSITIONS de statut sont loguées côté contrôleur (`Recommendation
  /// refresh: … -> …`). Les erreurs (HTTP/backend/réseau) restent journalisées.
  static bool _isNoisyPoll(RequestOptions options) =>
      options.path.contains('/api/recommendations/status');

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (!_isNoisyPoll(options)) {
      debugPrint('[API] --> ${options.method} ${options.uri}');
    }
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    final status = response.statusCode ?? 0;
    final isSuccess = status >= 200 && status < 400;
    // On tait UNIQUEMENT les sondes de statut RÉUSSIES ; toute réponse d'erreur
    // (y compris sur cet endpoint) est journalisée.
    if (!(_isNoisyPoll(response.requestOptions) && isSuccess)) {
      debugPrint(
        '[API] <-- $status '
        '${response.requestOptions.method} ${response.requestOptions.uri}',
      );
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    debugPrint(
      '[API] !! ${err.requestOptions.method} '
      '${err.requestOptions.uri} ${err.message}',
    );
    handler.next(err);
  }
}
