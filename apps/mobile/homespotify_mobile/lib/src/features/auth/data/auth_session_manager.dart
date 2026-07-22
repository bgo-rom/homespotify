import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/logging/app_logger.dart';
import '../../player/audio/audio_diagnostics.dart';
import 'token_store.dart';

/// Détient les tokens en mémoire, les persiste dans le stockage sécurisé et
/// garantit qu'UN SEUL refresh est en vol à la fois (single-flight) : les
/// requêtes concurrentes qui reçoivent un 401 partagent le même Future.
class AuthSessionManager {
  AuthSessionManager({
    required this._store,
    required this._refreshDio,
    this._proactiveRefreshLead = const Duration(seconds: 90),
    this._proactiveRefreshRetryDelay = const Duration(seconds: 30),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final TokenStore _store;

  /// Dio nu (sans intercepteur auth) : le refresh ne doit jamais repasser
  /// par l'intercepteur qui pourrait re-déclencher un refresh — pas de boucle.
  final Dio _refreshDio;
  final Duration _proactiveRefreshLead;
  final Duration _proactiveRefreshRetryDelay;
  final DateTime Function() _clock;

  AuthTokens? _tokens;
  Future<bool>? _refreshInFlight;
  Timer? _proactiveRefreshTimer;
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

  bool get accessTokenNeedsRefresh {
    final expiresIn = accessTokenExpiresIn;
    return expiresIn != null && expiresIn <= _proactiveRefreshLead;
  }

  /// Indication locale non securitaire extraite du claim JWT `exp`.
  /// Le serveur reste la seule autorite ; cette valeur sert uniquement a ne
  /// pas construire une nouvelle file audio avec un token presque expire.
  Duration? get accessTokenExpiresIn {
    final token = accessToken;
    if (token == null) return null;
    final parts = token.split('.');
    if (parts.length != 3) return null;
    try {
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      if (payload is! Map<String, dynamic>) return null;
      final exp = payload['exp'];
      if (exp is! num) return null;
      final expiresAt = DateTime.fromMillisecondsSinceEpoch(
        exp.toInt() * 1000,
        isUtc: true,
      );
      return expiresAt.difference(_clock().toUtc());
    } on FormatException {
      return null;
    }
  }

  Future<void> initialize() async {
    _tokens = await _store.readTokens();
    _scheduleProactiveRefresh();
    _notifySessionChanged();
  }

  Future<void> storeSession(AuthTokens tokens) async {
    _tokens = tokens;
    await _store.saveTokens(tokens);
    _scheduleProactiveRefresh();
    _notifySessionChanged();
  }

  Future<void> clearSession() async {
    _proactiveRefreshTimer?.cancel();
    _proactiveRefreshTimer = null;
    _tokens = null;
    await _store.clearTokens();
    _notifySessionChanged();
  }

  void _scheduleProactiveRefresh({Duration? retryAfter}) {
    _proactiveRefreshTimer?.cancel();
    _proactiveRefreshTimer = null;
    if (_tokens == null) return;
    final expiresIn = accessTokenExpiresIn;
    if (expiresIn == null) return;
    final delay = retryAfter ?? expiresIn - _proactiveRefreshLead;
    final boundedDelay = delay.isNegative ? Duration.zero : delay;
    AudioDiagnostics.instance.log('AUTH_PROACTIVE_REFRESH_SCHEDULED', {
      'delayMs': boundedDelay.inMilliseconds,
      'tokenExpiresInMs': expiresIn.inMilliseconds,
      'retry': retryAfter != null,
    });
    _proactiveRefreshTimer = Timer(boundedDelay, () {
      _proactiveRefreshTimer = null;
      unawaited(_runProactiveRefresh());
    });
  }

  Future<void> _runProactiveRefresh() async {
    if (_tokens == null) return;
    AudioDiagnostics.instance.log('AUTH_PROACTIVE_REFRESH_REQUESTED');
    final refreshed = await refreshSession();
    if (refreshed || _tokens == null) return;
    // Une panne réseau temporaire ne détruit pas la session. Le 401 réactif du
    // lecteur reste un dernier filet de sécurité pendant ces nouvelles
    // tentatives bornées dans le temps.
    _scheduleProactiveRefresh(retryAfter: _proactiveRefreshRetryDelay);
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
    if (inFlight != null) {
      AudioDiagnostics.instance.log('AUDIO_TOKEN_REFRESH_SINGLE_FLIGHT_JOINED');
      return inFlight;
    }
    final future = _doRefresh().whenComplete(() => _refreshInFlight = null);
    _refreshInFlight = future;
    return future;
  }

  /// Filet de sécurité pour les réveils Android et les timers suspendus en
  /// arrière-plan. Une requête ordinaire ou un retour réseau renouvelle le
  /// jeton seulement lorsqu'il approche réellement de son expiration.
  Future<bool> ensureFreshSession({bool force = false}) async {
    if (_tokens == null) return false;
    if (!force && !accessTokenNeedsRefresh) return true;
    return refreshSession();
  }

  Future<void> handleConnectivityRestored() async {
    if (_tokens == null) return;
    AudioDiagnostics.instance.log('AUTH_CONNECTIVITY_RESTORED', {
      'tokenExpiresInMs': accessTokenExpiresIn?.inMilliseconds,
      'refreshNeeded': accessTokenNeedsRefresh,
    });
    await ensureFreshSession();
  }

  Future<bool> _doRefresh() async {
    final current = _tokens;
    if (current == null) return false;
    final diagnostics = AudioDiagnostics.instance;
    final refreshId = diagnostics.nextId('auth-refresh');
    final stopwatch = Stopwatch()..start();
    diagnostics.log('AUDIO_TOKEN_REFRESH_STARTED', {
      'authRefreshId': refreshId,
      'tokenPresent': true,
      'tokenExpiresInMs': accessTokenExpiresIn?.inMilliseconds,
    });
    try {
      final response = await _refreshDio.post<Map<String, dynamic>>(
        '/api/auth/refresh',
        data: {'refreshToken': current.refreshToken},
      );
      final data = response.data;
      if (response.statusCode == 200 && data != null) {
        if (!identical(_tokens, current)) {
          return false;
        }
        await storeSession(
          AuthTokens(
            accessToken: data['accessToken'] as String,
            refreshToken: data['refreshToken'] as String,
          ),
        );
        logNetwork('session rafraîchie');
        diagnostics.log('AUDIO_TOKEN_REFRESH_COMPLETED', {
          'authRefreshId': refreshId,
          'refreshDurationMs': stopwatch.elapsedMilliseconds,
          'refreshResult': true,
          'tokenExpiresInMs': accessTokenExpiresIn?.inMilliseconds,
        });
        return true;
      }
      // 401 : refresh token consommé, révoqué ou expiré → session morte.
      logNetwork('refresh refusé (${response.statusCode}) : session expirée');
      await clearSession();
      onSessionExpired?.call();
      diagnostics.log('AUDIO_TOKEN_REFRESH_FAILED', {
        'authRefreshId': refreshId,
        'refreshDurationMs': stopwatch.elapsedMilliseconds,
        'refreshResult': false,
        'httpStatus': response.statusCode,
        'errorCode': 'SESSION_EXPIRED',
      });
      return false;
    } on DioException catch (error) {
      // Panne réseau : la session n'est PAS invalidée, on retentera plus tard.
      logNetwork('refresh impossible (réseau)');
      diagnostics.log('AUDIO_TOKEN_REFRESH_FAILED', {
        'authRefreshId': refreshId,
        'refreshDurationMs': stopwatch.elapsedMilliseconds,
        'refreshResult': false,
        'httpStatus': error.response?.statusCode,
        'errorCode': error.type.name,
      });
      return false;
    } catch (error) {
      // Une réponse 200 mal formée ou une erreur de stockage ne doit ni
      // invalider la session existante, ni bloquer l'intercepteur Dio.
      logNetwork('refresh impossible (réponse invalide)');
      diagnostics.log('AUDIO_TOKEN_REFRESH_FAILED', {
        'authRefreshId': refreshId,
        'refreshDurationMs': stopwatch.elapsedMilliseconds,
        'refreshResult': false,
        'errorCode': error.runtimeType.toString(),
      });
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
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (!_noRetryPaths.contains(options.path) && _manager.hasSession) {
      await _manager.ensureFreshSession();
    }
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
