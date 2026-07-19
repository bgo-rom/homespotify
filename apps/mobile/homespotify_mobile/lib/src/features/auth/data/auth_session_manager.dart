import 'dart:async';

import 'package:dio/dio.dart';

import '../../../core/logging/app_logger.dart';
import 'token_store.dart';

/// Détient les tokens en mémoire, les persiste dans le stockage sécurisé et
/// garantit qu'UN SEUL refresh est en vol à la fois (single-flight) : les
/// requêtes concurrentes qui reçoivent un 401 partagent le même Future.
class AuthSessionManager {
  AuthSessionManager({required this._store, required this._refreshDio});

  final TokenStore _store;

  /// Dio nu (sans intercepteur auth) : le refresh ne doit jamais repasser
  /// par l'intercepteur qui pourrait re-déclencher un refresh — pas de boucle.
  final Dio _refreshDio;

  AuthTokens? _tokens;
  Future<bool>? _refreshInFlight;
  final StreamController<int> _sessionChanges = StreamController<int>.broadcast(
    sync: true,
  );
  int _sessionRevision = 0;

  /// Appelé quand un refresh échoue définitivement : le contrôleur d'auth
  /// déconnecte proprement.
  void Function()? onSessionExpired;

  String? get accessToken => _tokens?.accessToken;
  String? get refreshToken => _tokens?.refreshToken;
  bool get hasSession => _tokens != null;
  Stream<int> get sessionChanges => _sessionChanges.stream;

  Future<void> initialize() async {
    _tokens = await _store.readTokens();
    _notifySessionChanged();
  }

  Future<void> storeSession(AuthTokens tokens) async {
    _tokens = tokens;
    await _store.saveTokens(tokens);
    _notifySessionChanged();
  }

  Future<void> clearSession() async {
    _tokens = null;
    await _store.clearTokens();
    _notifySessionChanged();
  }

  void _notifySessionChanged() {
    if (!_sessionChanges.isClosed) {
      _sessionChanges.add(++_sessionRevision);
    }
  }

  /// Rafraîchit la session. Retourne false si la session est définitivement
  /// invalide (le client doit se déconnecter).
  Future<bool> refreshSession() {
    final inFlight = _refreshInFlight;
    if (inFlight != null) return inFlight;
    final future = _doRefresh().whenComplete(() => _refreshInFlight = null);
    _refreshInFlight = future;
    return future;
  }

  Future<bool> _doRefresh() async {
    final current = _tokens;
    if (current == null) return false;
    try {
      final response = await _refreshDio.post<Map<String, dynamic>>(
        '/api/auth/refresh',
        data: {'refreshToken': current.refreshToken},
      );
      final data = response.data;
      if (response.statusCode == 200 && data != null) {
        await storeSession(
          AuthTokens(
            accessToken: data['accessToken'] as String,
            refreshToken: data['refreshToken'] as String,
          ),
        );
        logNetwork('session rafraîchie');
        return true;
      }
      // 401 : refresh token consommé, révoqué ou expiré → session morte.
      logNetwork('refresh refusé (${response.statusCode}) : session expirée');
      await clearSession();
      onSessionExpired?.call();
      return false;
    } on DioException {
      // Panne réseau : la session n'est PAS invalidée, on retentera plus tard.
      logNetwork('refresh impossible (réseau)');
      return false;
    }
  }
}

/// Intercepteur du Dio partagé : injecte le Bearer et rejoue UNE seule fois
/// une requête 401 après refresh réussi. Jamais de boucle : la retentative
/// est marquée dans `extra` et les routes d'authentification sont exclues.
class AuthInterceptor extends Interceptor {
  AuthInterceptor(this._manager);

  static const _retriedFlag = 'homespotify_auth_retried';
  static const _noRetryPaths = {
    '/api/auth/login',
    '/api/auth/refresh',
    '/api/auth/bootstrap',
    '/api/auth/bootstrap-status',
    '/api/auth/logout',
  };

  final AuthSessionManager _manager;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final token = _manager.accessToken;
    if (token != null && !options.headers.containsKey('Authorization')) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  @override
  Future<void> onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) async {
    // Le Dio partagé considère les 4xx comme des réponses (validateStatus
    // < 500), donc le 401 arrive ici et non dans onError.
    final options = response.requestOptions;
    if (response.statusCode != 401 ||
        !_manager.hasSession ||
        options.extra[_retriedFlag] == true ||
        _noRetryPaths.contains(options.path)) {
      handler.next(response);
      return;
    }

    final refreshed = await _manager.refreshSession();
    if (!refreshed) {
      handler.next(response);
      return;
    }

    try {
      final retried = await _retry(options);
      handler.resolve(retried);
    } on DioException {
      handler.next(response);
    }
  }

  Future<Response<dynamic>> _retry(RequestOptions options) {
    final dio = Dio(
      BaseOptions(
        baseUrl: options.baseUrl,
        connectTimeout: options.connectTimeout,
        receiveTimeout: options.receiveTimeout,
        sendTimeout: options.sendTimeout,
        responseType: options.responseType,
        validateStatus: options.validateStatus,
      ),
    );
    final headers = Map<String, dynamic>.from(options.headers)
      ..['Authorization'] = 'Bearer ${_manager.accessToken}';
    return dio.request<dynamic>(
      options.path,
      data: options.data,
      queryParameters: options.queryParameters,
      options: Options(
        method: options.method,
        headers: headers,
        extra: {...options.extra, _retriedFlag: true},
      ),
    );
  }
}
