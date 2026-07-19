import 'package:dio/dio.dart';

import '../../../core/config/app_config.dart';
import '../domain/auth_user.dart';
import 'token_store.dart';

/// Erreur d'API auth avec message affichable tel quel.
class AuthApiException implements Exception {
  const AuthApiException(this.message, {this.statusCode, this.code});

  final String message;
  final int? statusCode;
  final String? code;

  bool get isNetworkError => statusCode == null;

  @override
  String toString() => 'AuthApiException($statusCode/$code): $message';
}

/// Résultat d'une émission de session (bootstrap, login, change-password).
class AuthPayload {
  const AuthPayload({required this.user, required this.tokens});

  final AuthUser user;
  final AuthTokens tokens;

  static AuthPayload fromJson(Map<String, dynamic> json) {
    return AuthPayload(
      user: AuthUser.fromJson(json['user'] as Map<String, dynamic>),
      tokens: AuthTokens(
        accessToken: json['accessToken'] as String,
        refreshToken: json['refreshToken'] as String,
      ),
    );
  }
}

/// Client des routes /api/auth. Le Dio partagé passe par l'intercepteur
/// Bearer ; les mots de passe ne sont jamais journalisés ni conservés.
class AuthApi {
  AuthApi(this._dio);

  final Dio _dio;

  Future<bool> bootstrapRequired() async {
    final response = await _request<Map<String, dynamic>>(
      () => _dio.get('/api/auth/bootstrap-status'),
    );
    return response['bootstrapRequired'] as bool? ?? false;
  }

  Future<AuthPayload> bootstrap({
    required String username,
    required String displayName,
    required String password,
    required String passwordConfirmation,
    String? deviceName,
  }) async {
    final json = await _request<Map<String, dynamic>>(
      () => _dio.post(
        '/api/auth/bootstrap',
        data: {
          'username': username,
          'displayName': displayName,
          'password': password,
          'passwordConfirmation': passwordConfirmation,
          'deviceName': ?deviceName,
        },
      ),
    );
    return AuthPayload.fromJson(json);
  }

  Future<AuthPayload> login({
    required String username,
    required String password,
    String? deviceName,
  }) async {
    final json = await _request<Map<String, dynamic>>(
      () => _dio.post(
        '/api/auth/login',
        data: {
          'username': username,
          'password': password,
          'deviceName': ?deviceName,
        },
      ),
    );
    return AuthPayload.fromJson(json);
  }

  Future<AuthUser> me() async {
    final json = await _request<Map<String, dynamic>>(
      () => _dio.get('/api/auth/me'),
    );
    return AuthUser.fromJson(json['user'] as Map<String, dynamic>);
  }

  Future<AuthPayload> changePassword({
    required String currentPassword,
    required String newPassword,
    required String newPasswordConfirmation,
    String? deviceName,
  }) async {
    final json = await _request<Map<String, dynamic>>(
      () => _dio.post(
        '/api/auth/change-password',
        data: {
          'currentPassword': currentPassword,
          'newPassword': newPassword,
          'newPasswordConfirmation': newPasswordConfirmation,
          'deviceName': ?deviceName,
        },
      ),
    );
    return AuthPayload.fromJson(json);
  }

  Future<void> logout({required String refreshToken}) async {
    try {
      await _dio.post('/api/auth/logout', data: {'refreshToken': refreshToken});
    } on DioException {
      // Déconnexion locale prioritaire : un serveur injoignable ne doit pas
      // bloquer le logout côté appareil.
    }
  }

  Future<T> _request<T>(
    Future<Response<dynamic>> Function() send, {
    Set<int> allowedStatuses = const {200, 201},
  }) async {
    Response<dynamic> response;
    try {
      response = await send();
    } on DioException {
      throw const AuthApiException(AppConfig.serverUnreachableMessage);
    }
    final status = response.statusCode ?? 0;
    if (!allowedStatuses.contains(status)) {
      final data = response.data;
      final message = data is Map<String, dynamic>
          ? data['message'] as String? ?? 'Requête refusée.'
          : 'Requête refusée.';
      final code = data is Map<String, dynamic>
          ? data['error'] as String?
          : null;
      throw AuthApiException(message, statusCode: status, code: code);
    }
    return response.data as T;
  }
}
