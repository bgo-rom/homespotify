import 'package:local_auth/local_auth.dart';

import '../../../core/logging/app_logger.dart';

enum BiometricFailureReason {
  notConfigured,
  unavailable,
  canceled,
  lockedOut,
  androidError,
  rejected,
}

class BiometricAvailability {
  const BiometricAvailability({
    required this.available,
    required this.deviceSupported,
    required this.canCheckBiometrics,
    required this.types,
    this.failureReason,
  });

  final bool available;
  final bool deviceSupported;
  final bool canCheckBiometrics;
  final List<BiometricType> types;
  final BiometricFailureReason? failureReason;
}

class BiometricAuthenticationResult {
  const BiometricAuthenticationResult._({
    required this.succeeded,
    this.failureReason,
  });

  const BiometricAuthenticationResult.success() : this._(succeeded: true);

  const BiometricAuthenticationResult.failure(BiometricFailureReason reason)
    : this._(succeeded: false, failureReason: reason);

  final bool succeeded;
  final BiometricFailureReason? failureReason;

  String get userMessage => switch (failureReason) {
    BiometricFailureReason.notConfigured =>
      'Aucune biométrie n’est configurée dans Android.',
    BiometricFailureReason.unavailable =>
      'La biométrie est indisponible sur cet appareil.',
    BiometricFailureReason.canceled => 'Demande biométrique annulée.',
    BiometricFailureReason.lockedOut =>
      'Trop de tentatives. Réessayez après le déverrouillage Android.',
    BiometricFailureReason.androidError =>
      'Erreur Android pendant la demande biométrique.',
    BiometricFailureReason.rejected => 'Authentification biométrique refusée.',
    null => '',
  };
}

abstract interface class BiometricAuthenticator {
  Future<bool> isDeviceSupported();
  Future<bool> canCheckBiometrics();
  Future<List<BiometricType>> getAvailableBiometrics();
  Future<bool> authenticateBiometric({required String localizedReason});
}

class LocalAuthBiometricAuthenticator implements BiometricAuthenticator {
  LocalAuthBiometricAuthenticator([LocalAuthentication? auth])
    : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<bool> isDeviceSupported() => _auth.isDeviceSupported();

  @override
  Future<bool> canCheckBiometrics() => _auth.canCheckBiometrics;

  @override
  Future<List<BiometricType>> getAvailableBiometrics() =>
      _auth.getAvailableBiometrics();

  @override
  Future<bool> authenticateBiometric({required String localizedReason}) {
    return _auth.authenticate(
      localizedReason: localizedReason,
      biometricOnly: true,
      sensitiveTransaction: true,
      persistAcrossBackgrounding: true,
    );
  }
}

/// Biométrie locale uniquement : aucune donnée biométrique ni mot de passe ne
/// quitte Android ou n'est stocké par HomeSpotify.
class BiometricService {
  BiometricService({BiometricAuthenticator? authenticator})
    : _authenticator = authenticator ?? LocalAuthBiometricAuthenticator();

  final BiometricAuthenticator _authenticator;

  Future<BiometricAvailability> checkAvailability() async {
    try {
      final deviceSupported = await _authenticator.isDeviceSupported();
      final canCheck = await _authenticator.canCheckBiometrics();
      final types = await _authenticator.getAvailableBiometrics();
      // La liste non vide est la preuve qu'Android expose une biométrie
      // utilisable. Ne pas la rejeter à cause d'un booléen constructeur
      // incohérent sur certains appareils/OEM.
      final available = types.isNotEmpty;
      logUi(
        'biométrie disponibilité deviceSupported=$deviceSupported '
        'canCheckBiometrics=$canCheck types=${types.map((type) => type.name).join(',')}',
      );
      return BiometricAvailability(
        available: available,
        deviceSupported: deviceSupported,
        canCheckBiometrics: canCheck,
        types: List<BiometricType>.unmodifiable(types),
        failureReason: available
            ? null
            : types.isEmpty && (deviceSupported || canCheck)
            ? BiometricFailureReason.notConfigured
            : BiometricFailureReason.unavailable,
      );
    } on LocalAuthException catch (error, stackTrace) {
      _logLocalAuthException('détection biométrique', error, stackTrace);
      return BiometricAvailability(
        available: false,
        deviceSupported: false,
        canCheckBiometrics: false,
        types: const [],
        failureReason: _reasonForCode(error.code),
      );
    } catch (error, stackTrace) {
      logError(
        'erreur Android pendant la détection biométrique type=${error.runtimeType}',
        stackTrace: stackTrace,
      );
      return const BiometricAvailability(
        available: false,
        deviceSupported: false,
        canCheckBiometrics: false,
        types: [],
        failureReason: BiometricFailureReason.androidError,
      );
    }
  }

  Future<bool> isSupported() async => (await checkAvailability()).available;

  Future<BiometricAuthenticationResult> authenticateDetailed({
    String localizedReason = 'Authentifiez-vous pour accéder à HomeSpotify',
  }) async {
    logUi('début demande biométrique');
    try {
      final authenticated = await _authenticator.authenticateBiometric(
        localizedReason: localizedReason,
      );
      logUi('résultat demande biométrique=$authenticated');
      return authenticated
          ? const BiometricAuthenticationResult.success()
          : const BiometricAuthenticationResult.failure(
              BiometricFailureReason.rejected,
            );
    } on LocalAuthException catch (error, stackTrace) {
      _logLocalAuthException('authentification biométrique', error, stackTrace);
      return BiometricAuthenticationResult.failure(_reasonForCode(error.code));
    } catch (error, stackTrace) {
      logError(
        'erreur Android pendant authentification biométrique type=${error.runtimeType}',
        stackTrace: stackTrace,
      );
      return const BiometricAuthenticationResult.failure(
        BiometricFailureReason.androidError,
      );
    }
  }

  Future<bool> authenticate() async => (await authenticateDetailed()).succeeded;

  void _logLocalAuthException(
    String operation,
    LocalAuthException error,
    StackTrace stackTrace,
  ) {
    final description = _cleanDescription(error.description);
    logError(
      '$operation code=${error.code.name} message=$description',
      stackTrace: stackTrace,
    );
  }

  static String _cleanDescription(String? value) {
    if (value == null || value.trim().isEmpty) return '<aucun détail>';
    final cleaned = value
        .replaceAll(RegExp(r'[\r\n]+'), ' ')
        .replaceAll(
          RegExp(r'(token|password|cookie)\s*[:=]\s*\S+', caseSensitive: false),
          r'$1=<redacted>',
        )
        .trim();
    return cleaned.length <= 200 ? cleaned : cleaned.substring(0, 200);
  }

  static BiometricFailureReason _reasonForCode(LocalAuthExceptionCode code) {
    return switch (code) {
      LocalAuthExceptionCode.noCredentialsSet ||
      LocalAuthExceptionCode.noBiometricsEnrolled =>
        BiometricFailureReason.notConfigured,
      LocalAuthExceptionCode.noBiometricHardware ||
      LocalAuthExceptionCode.biometricHardwareTemporarilyUnavailable =>
        BiometricFailureReason.unavailable,
      LocalAuthExceptionCode.userCanceled ||
      LocalAuthExceptionCode.systemCanceled ||
      LocalAuthExceptionCode.userRequestedFallback ||
      LocalAuthExceptionCode.timeout => BiometricFailureReason.canceled,
      LocalAuthExceptionCode.temporaryLockout ||
      LocalAuthExceptionCode.biometricLockout =>
        BiometricFailureReason.lockedOut,
      _ => BiometricFailureReason.androidError,
    };
  }
}
