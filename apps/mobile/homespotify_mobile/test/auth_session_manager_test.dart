import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:homespotify_mobile/src/features/auth/data/auth_session_manager.dart';
import 'package:homespotify_mobile/src/features/auth/data/token_store.dart';

void main() {
  test('la session renouvelle le JWT avant son expiration', () async {
    final now = DateTime.utc(2026, 7, 20, 16);
    final renewedAccessToken = _jwtExpiringAt(
      now.add(const Duration(hours: 1)),
    );
    final adapter = _RefreshAdapter(
      accessToken: renewedAccessToken,
      refreshToken: 'refresh-renewed',
    );
    final dio = Dio(BaseOptions(baseUrl: 'https://homespotify.test'))
      ..httpClientAdapter = adapter;
    final store = _MemoryTokenStore(
      AuthTokens(
        accessToken: _jwtExpiringAt(now.add(const Duration(seconds: 30))),
        refreshToken: 'refresh-initial',
      ),
    );
    final manager = AuthSessionManager(
      store: store,
      refreshDio: dio,
      proactiveRefreshLead: const Duration(seconds: 90),
      clock: () => now,
    );
    addTearDown(manager.clearSession);

    await manager.initialize();
    await adapter.requested.future.timeout(const Duration(seconds: 1));
    await _settleUntil(() => store.tokens?.accessToken == renewedAccessToken);

    expect(adapter.calls, 1);
    expect(store.tokens?.refreshToken, 'refresh-renewed');
    expect(manager.accessTokenExpiresIn, const Duration(hours: 1));
  });

  test('les renouvellements concurrents partagent une seule requête', () async {
    final now = DateTime.utc(2026, 7, 21, 10);
    final adapter = _RefreshAdapter(
      accessToken: _jwtExpiringAt(now.add(const Duration(hours: 1))),
      refreshToken: 'refresh-renewed',
    );
    final dio = Dio(BaseOptions(baseUrl: 'https://homespotify.test'))
      ..httpClientAdapter = adapter;
    final store = _MemoryTokenStore(
      AuthTokens(
        accessToken: _jwtExpiringAt(now.add(const Duration(minutes: 5))),
        refreshToken: 'refresh-initial',
      ),
    );
    final manager = AuthSessionManager(
      store: store,
      refreshDio: dio,
      clock: () => now,
    );
    addTearDown(manager.clearSession);
    await manager.initialize();

    final results = await Future.wait([
      manager.refreshSession(),
      manager.refreshSession(),
      manager.refreshSession(),
    ]);

    expect(results, everyElement(isTrue));
    expect(adapter.calls, 1);
  });

  test('une panne réseau ne détruit jamais la session locale', () async {
    final now = DateTime.utc(2026, 7, 21, 10);
    final dio = Dio(BaseOptions(baseUrl: 'https://homespotify.test'))
      ..httpClientAdapter = _NetworkFailureAdapter();
    final initial = AuthTokens(
      accessToken: _jwtExpiringAt(now.add(const Duration(minutes: 5))),
      refreshToken: 'refresh-still-valid',
    );
    final store = _MemoryTokenStore(initial);
    final manager = AuthSessionManager(
      store: store,
      refreshDio: dio,
      clock: () => now,
    );
    addTearDown(manager.clearSession);
    await manager.initialize();

    expect(await manager.refreshSession(), isFalse);
    expect(manager.hasSession, isTrue);
    expect(store.tokens?.refreshToken, initial.refreshToken);
  });
}

Future<void> _settleUntil(bool Function() condition) async {
  for (var turn = 0; turn < 100 && !condition(); turn++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}

String _jwtExpiringAt(DateTime expiresAt) {
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${encode({'alg': 'none'})}.${encode({'exp': expiresAt.millisecondsSinceEpoch ~/ 1000})}.';
}

class _RefreshAdapter implements HttpClientAdapter {
  _RefreshAdapter({required this.accessToken, required this.refreshToken});

  final String accessToken;
  final String refreshToken;
  final Completer<void> requested = Completer<void>();
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls += 1;
    if (!requested.isCompleted) requested.complete();
    expect(options.path, '/api/auth/refresh');
    return ResponseBody.fromString(
      jsonEncode({'accessToken': accessToken, 'refreshToken': refreshToken}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _NetworkFailureAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    throw DioException.connectionError(
      requestOptions: options,
      reason: 'offline',
    );
  }

  @override
  void close({bool force = false}) {}
}

class _MemoryTokenStore implements TokenStore {
  _MemoryTokenStore(this.tokens);

  AuthTokens? tokens;
  String? localIdentityJson;

  @override
  Future<String?> readLocalIdentityJson() async => localIdentityJson;

  @override
  Future<void> saveLocalIdentityJson(String json) async =>
      localIdentityJson = json;

  @override
  Future<void> clearLocalIdentity() async => localIdentityJson = null;

  @override
  Future<AuthTokens?> readTokens() async => tokens;

  @override
  Future<void> saveTokens(AuthTokens value) async => tokens = value;

  @override
  Future<void> clearTokens() async => tokens = null;

  @override
  Future<bool> readBiometricEnabled() async => false;

  @override
  Future<void> saveBiometricEnabled(bool enabled) async {}
}
