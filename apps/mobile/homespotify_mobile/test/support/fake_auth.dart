import 'dart:async';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:local_auth/local_auth.dart';

import 'package:homespotify_mobile/src/features/auth/application/auth_controller.dart';
import 'package:homespotify_mobile/src/features/auth/data/auth_api.dart';
import 'package:homespotify_mobile/src/features/auth/data/auth_session_manager.dart';
import 'package:homespotify_mobile/src/features/auth/data/biometric_service.dart';
import 'package:homespotify_mobile/src/features/auth/data/token_store.dart';
import 'package:homespotify_mobile/src/features/auth/domain/auth_user.dart';

AuthUser makeUser({
  int id = 1,
  String username = 'romain',
  String role = 'OWNER',
  bool mustChangePassword = false,
}) {
  return AuthUser(
    id: id,
    username: username,
    displayName: username,
    role: role,
    isActive: true,
    mustChangePassword: mustChangePassword,
  );
}

class FakeTokenStore implements TokenStore {
  AuthTokens? tokens;
  bool biometricEnabled = false;
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
  Future<bool> readBiometricEnabled() async => biometricEnabled;

  @override
  Future<void> saveBiometricEnabled(bool enabled) async =>
      biometricEnabled = enabled;
}

class FakeBiometricService implements BiometricService {
  FakeBiometricService({
    this.supported = false,
    this.authenticateResult = false,
  });

  bool supported;
  bool authenticateResult;
  BiometricFailureReason availabilityFailureReason =
      BiometricFailureReason.unavailable;
  BiometricFailureReason authenticateFailureReason =
      BiometricFailureReason.rejected;
  int authenticateCalls = 0;

  @override
  Future<BiometricAvailability> checkAvailability() async {
    return BiometricAvailability(
      available: supported,
      deviceSupported: supported,
      canCheckBiometrics: supported,
      types: supported ? const [BiometricType.fingerprint] : const [],
      failureReason: supported ? null : availabilityFailureReason,
    );
  }

  @override
  Future<bool> isSupported() async => supported;

  @override
  Future<bool> authenticate() async {
    authenticateCalls += 1;
    return authenticateResult;
  }

  @override
  Future<BiometricAuthenticationResult> authenticateDetailed({
    String localizedReason = 'Authentifiez-vous pour accéder à HomeSpotify',
  }) async {
    authenticateCalls += 1;
    return authenticateResult
        ? const BiometricAuthenticationResult.success()
        : BiometricAuthenticationResult.failure(authenticateFailureReason);
  }
}

class FakeSessionManager implements AuthSessionManager {
  FakeSessionManager({this.store});

  final FakeTokenStore? store;
  AuthTokens? tokens;
  bool refreshResult = true;
  final StreamController<int> _sessionChanges = StreamController<int>.broadcast(
    sync: true,
  );
  int _sessionRevision = 0;

  @override
  void Function()? onSessionExpired;

  @override
  String? get accessToken => tokens?.accessToken;

  @override
  Duration? get accessTokenExpiresIn => null;

  @override
  bool get accessTokenNeedsRefresh => false;

  @override
  String? get refreshToken => tokens?.refreshToken;

  @override
  bool get hasSession => tokens != null;

  @override
  Stream<int> get sessionChanges => _sessionChanges.stream;

  @override
  Future<void> initialize() async {
    tokens = await store?.readTokens();
    _sessionChanges.add(++_sessionRevision);
  }

  @override
  Future<void> storeSession(AuthTokens value) async {
    tokens = value;
    await store?.saveTokens(value);
    _sessionChanges.add(++_sessionRevision);
  }

  @override
  Future<void> clearSession() async {
    tokens = null;
    await store?.clearTokens();
    _sessionChanges.add(++_sessionRevision);
  }

  @override
  Future<bool> refreshSession() async => refreshResult;

  @override
  Future<bool> ensureFreshSession({bool force = false}) async {
    if (!hasSession) return false;
    return force ? refreshSession() : true;
  }

  @override
  Future<void> handleConnectivityRestored() async {
    await ensureFreshSession();
  }
}

/// Fake API auth scriptable : chaque champ nul déclenche une erreur réseau.
class FakeAuthApi implements AuthApi {
  bool bootstrapRequiredResult = false;
  bool networkDown = false;
  AuthUser? meResult;
  AuthPayload? loginResult;
  AuthApiException? loginError;
  AuthPayload? bootstrapResult;
  AuthPayload? changePasswordResult;
  int logoutCalls = 0;

  static AuthPayload payloadFor(AuthUser user) => AuthPayload(
    user: user,
    tokens: const AuthTokens(accessToken: 'access', refreshToken: 'refresh'),
  );

  void _failIfDown() {
    if (networkDown) {
      throw const AuthApiException('Serveur HomeSpotify inaccessible.');
    }
  }

  @override
  Future<bool> bootstrapRequired() async {
    _failIfDown();
    return bootstrapRequiredResult;
  }

  @override
  Future<AuthPayload> bootstrap({
    required String username,
    required String displayName,
    required String password,
    required String passwordConfirmation,
    String? deviceName,
  }) async {
    _failIfDown();
    final result = bootstrapResult;
    if (result == null) {
      throw const AuthApiException('Bootstrap refusé.', statusCode: 409);
    }
    return result;
  }

  @override
  Future<AuthPayload> login({
    required String username,
    required String password,
    String? deviceName,
  }) async {
    _failIfDown();
    final error = loginError;
    if (error != null) throw error;
    final result = loginResult;
    if (result == null) {
      throw const AuthApiException('Identifiants invalides.', statusCode: 401);
    }
    return result;
  }

  @override
  Future<AuthUser> me() async {
    _failIfDown();
    final user = meResult;
    if (user == null) {
      throw const AuthApiException(
        'Authentification requise.',
        statusCode: 401,
      );
    }
    return user;
  }

  @override
  Future<AuthPayload> changePassword({
    required String currentPassword,
    required String newPassword,
    required String newPasswordConfirmation,
    String? deviceName,
  }) async {
    _failIfDown();
    final result = changePasswordResult;
    if (result == null) {
      throw const AuthApiException('Mot de passe refusé.', statusCode: 400);
    }
    return result;
  }

  @override
  Future<void> logout({required String refreshToken}) async {
    logoutCalls += 1;
  }
}

/// Contrôleur stub pour les tests de widgets : état figé, aucune résolution
/// asynchrone au montage.
class StubAuthController extends AuthController {
  StubAuthController(this._initial);

  final AuthState _initial;

  @override
  AuthState build() => _initial;
}

/// Overrides standards pour monter un widget dépendant de l'auth.
List<Override> authOverrides({
  AuthState? state,
  FakeTokenStore? tokenStore,
  FakeBiometricService? biometrics,
  FakeAuthApi? api,
  FakeSessionManager? sessionManager,
}) {
  final store = tokenStore ?? FakeTokenStore();
  return [
    tokenStoreProvider.overrideWithValue(store),
    biometricServiceProvider.overrideWithValue(
      biometrics ?? FakeBiometricService(),
    ),
    authApiProvider.overrideWithValue(api ?? FakeAuthApi()),
    authSessionManagerProvider.overrideWithValue(
      sessionManager ?? FakeSessionManager(store: store),
    ),
    if (state != null)
      authControllerProvider.overrideWith(() => StubAuthController(state)),
  ];
}
