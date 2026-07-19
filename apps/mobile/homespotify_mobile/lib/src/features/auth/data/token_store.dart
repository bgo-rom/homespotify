import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Paire de tokens de session. Le mot de passe n'est JAMAIS stocké.
class AuthTokens {
  const AuthTokens({required this.accessToken, required this.refreshToken});

  final String accessToken;
  final String refreshToken;
}

/// Stockage des tokens — abstrait pour les tests.
abstract class TokenStore {
  Future<AuthTokens?> readTokens();
  Future<void> saveTokens(AuthTokens tokens);
  Future<void> clearTokens();
  Future<bool> readBiometricEnabled();
  Future<void> saveBiometricEnabled(bool enabled);
}

/// Implémentation réelle : Android Keystore via flutter_secure_storage.
/// Les tokens ne transitent jamais par les SharedPreferences en clair.
class SecureTokenStore implements TokenStore {
  SecureTokenStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _accessTokenKey = 'auth_access_token';
  static const _refreshTokenKey = 'auth_refresh_token';
  static const _biometricEnabledKey = 'auth_biometric_enabled';

  final FlutterSecureStorage _storage;

  @override
  Future<AuthTokens?> readTokens() async {
    final accessToken = await _storage.read(key: _accessTokenKey);
    final refreshToken = await _storage.read(key: _refreshTokenKey);
    if (accessToken == null ||
        refreshToken == null ||
        accessToken.isEmpty ||
        refreshToken.isEmpty) {
      return null;
    }
    return AuthTokens(accessToken: accessToken, refreshToken: refreshToken);
  }

  @override
  Future<void> saveTokens(AuthTokens tokens) async {
    await _storage.write(key: _accessTokenKey, value: tokens.accessToken);
    await _storage.write(key: _refreshTokenKey, value: tokens.refreshToken);
  }

  @override
  Future<void> clearTokens() async {
    await _storage.delete(key: _accessTokenKey);
    await _storage.delete(key: _refreshTokenKey);
  }

  @override
  Future<bool> readBiometricEnabled() async {
    return await _storage.read(key: _biometricEnabledKey) == 'true';
  }

  @override
  Future<void> saveBiometricEnabled(bool enabled) async {
    await _storage.write(key: _biometricEnabledKey, value: '$enabled');
  }
}
