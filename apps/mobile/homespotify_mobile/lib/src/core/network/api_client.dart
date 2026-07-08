import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const String homespotifyApiBaseUrl = String.fromEnvironment(
  'HOMESPOTIFY_API_BASE_URL',
  defaultValue: 'http://10.0.2.2:3000',
);

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
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    debugPrint('[API] --> ${options.method} ${options.uri}');
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    debugPrint(
      '[API] <-- ${response.statusCode} '
      '${response.requestOptions.method} ${response.requestOptions.uri}',
    );
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
