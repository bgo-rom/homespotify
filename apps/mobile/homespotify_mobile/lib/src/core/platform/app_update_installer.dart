import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Identité d'une APK lue SANS installation (PackageManager côté Android).
@immutable
class ApkIdentity {
  const ApkIdentity({
    required this.packageName,
    required this.versionCode,
    required this.versionName,
    required this.signingCertSha256,
  });

  final String packageName;
  final int versionCode;
  final String versionName;

  /// Empreintes SHA-256 des certificats signataires, en minuscules.
  final List<String> signingCertSha256;
}

/// Passerelle vers l'installateur Android. Aucune installation silencieuse :
/// chaque appel se termine par un écran système que l'utilisateur confirme.
abstract class AppUpdateInstaller {
  /// HomeSpotify est-il autorisé comme source d'installation ?
  Future<bool> canRequestInstall();

  /// Ouvre « Installer des applications inconnues » sur HomeSpotify.
  Future<bool> openInstallSettings();

  /// Lit l'identité de l'APK téléchargée. `null` si elle est illisible.
  Future<ApkIdentity?> inspectApk(String path);

  /// Remet l'APK à l'installateur du système.
  Future<void> installApk(String path);
}

class AndroidAppUpdateInstaller implements AppUpdateInstaller {
  const AndroidAppUpdateInstaller();

  static const MethodChannel _channel = MethodChannel(
    'com.homespotify/app_update',
  );

  @override
  Future<bool> canRequestInstall() async {
    final granted = await _channel.invokeMethod<bool>('canRequestInstall');
    return granted ?? false;
  }

  @override
  Future<bool> openInstallSettings() async {
    final opened = await _channel.invokeMethod<bool>('openInstallSettings');
    return opened ?? false;
  }

  @override
  Future<ApkIdentity?> inspectApk(String path) async {
    final Map<String, Object?>? raw;
    try {
      raw = await _channel.invokeMapMethod<String, Object?>('inspectApk', {
        'path': path,
      });
    } on PlatformException {
      return null;
    }
    if (raw == null) return null;
    final packageName = raw['packageName']?.toString() ?? '';
    final versionCode = int.tryParse(raw['versionCode']?.toString() ?? '');
    if (packageName.isEmpty || versionCode == null) return null;
    final certificates = raw['signingCertSha256'];
    return ApkIdentity(
      packageName: packageName,
      versionCode: versionCode,
      versionName: raw['versionName']?.toString() ?? '',
      signingCertSha256: certificates is List
          ? certificates
                .map((value) => value.toString().toLowerCase())
                .where((value) => value.isNotEmpty)
                .toList()
          : const <String>[],
    );
  }

  @override
  Future<void> installApk(String path) async {
    await _channel.invokeMethod<bool>('installApk', {'path': path});
  }
}
