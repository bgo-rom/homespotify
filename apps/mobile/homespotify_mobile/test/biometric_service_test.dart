import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';

import 'package:homespotify_mobile/src/features/auth/data/biometric_service.dart';

void main() {
  test('appareil non compatible : biométrie indisponible', () async {
    final service = BiometricService(authenticator: _FakeAuthenticator());
    final result = await service.checkAvailability();
    expect(result.available, isFalse);
    expect(result.failureReason, BiometricFailureReason.unavailable);
  });

  test('biométrie non enregistrée : message dédié', () async {
    final service = BiometricService(
      authenticator: _FakeAuthenticator(deviceSupported: true, canCheck: true),
    );
    final result = await service.checkAvailability();
    expect(result.available, isFalse);
    expect(result.failureReason, BiometricFailureReason.notConfigured);
  });

  test('empreinte disponible même sans classification strong', () async {
    final service = BiometricService(
      authenticator: _FakeAuthenticator(
        types: const [BiometricType.fingerprint],
      ),
    );
    final result = await service.checkAvailability();
    expect(result.available, isTrue);
    expect(result.types, contains(BiometricType.fingerprint));
  });

  test(
    'strong, weak et face sont acceptés comme biométries disponibles',
    () async {
      for (final type in const [
        BiometricType.strong,
        BiometricType.weak,
        BiometricType.face,
      ]) {
        final service = BiometricService(
          authenticator: _FakeAuthenticator(
            deviceSupported: true,
            types: [type],
          ),
        );
        expect((await service.checkAvailability()).available, isTrue);
      }
    },
  );

  test('authentification : succès puis refus sans exception', () async {
    final gateway = _FakeAuthenticator(authenticateResult: true);
    final service = BiometricService(authenticator: gateway);
    expect((await service.authenticateDetailed()).succeeded, isTrue);

    gateway.authenticateResult = false;
    final refused = await service.authenticateDetailed();
    expect(refused.succeeded, isFalse);
    expect(refused.failureReason, BiometricFailureReason.rejected);
  });

  test('annulation et verrouillage sont distingués', () async {
    final gateway = _FakeAuthenticator(
      authenticateError: const LocalAuthException(
        code: LocalAuthExceptionCode.userCanceled,
      ),
    );
    final service = BiometricService(authenticator: gateway);
    expect(
      (await service.authenticateDetailed()).failureReason,
      BiometricFailureReason.canceled,
    );

    gateway.authenticateError = const LocalAuthException(
      code: LocalAuthExceptionCode.temporaryLockout,
    );
    expect(
      (await service.authenticateDetailed()).failureReason,
      BiometricFailureReason.lockedOut,
    );
  });

  test('exception plugin devient erreur Android propre', () async {
    final service = BiometricService(
      authenticator: _FakeAuthenticator(
        availabilityError: StateError('plugin indisponible'),
      ),
    );
    final result = await service.checkAvailability();
    expect(result.available, isFalse);
    expect(result.failureReason, BiometricFailureReason.androidError);
  });
}

class _FakeAuthenticator implements BiometricAuthenticator {
  _FakeAuthenticator({
    this.deviceSupported = false,
    this.canCheck = false,
    this.types = const [],
    this.authenticateResult = false,
    this.availabilityError,
    this.authenticateError,
  });

  final bool deviceSupported;
  final bool canCheck;
  final List<BiometricType> types;
  bool authenticateResult;
  final Object? availabilityError;
  Object? authenticateError;

  void _throwAvailabilityError() {
    if (availabilityError != null) throw availabilityError!;
  }

  @override
  Future<bool> isDeviceSupported() async {
    _throwAvailabilityError();
    return deviceSupported;
  }

  @override
  Future<bool> canCheckBiometrics() async {
    _throwAvailabilityError();
    return canCheck;
  }

  @override
  Future<List<BiometricType>> getAvailableBiometrics() async {
    _throwAvailabilityError();
    return types;
  }

  @override
  Future<bool> authenticateBiometric({required String localizedReason}) async {
    if (authenticateError != null) throw authenticateError!;
    return authenticateResult;
  }
}
