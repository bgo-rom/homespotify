import 'package:flutter/services.dart';

class AppPackageInfo {
  const AppPackageInfo({
    required this.version,
    required this.buildNumber,
    this.packageName = '',
  });

  static const MethodChannel _channel = MethodChannel(
    'com.homespotify/app_info',
  );

  final String version;
  final String buildNumber;
  final String packageName;

  String get displayVersion =>
      buildNumber.isEmpty ? version : '$version+$buildNumber';

  /// `versionCode` Android — référence de comparaison des mises à jour.
  /// `null` si la plateforme n'a pas renvoyé un entier exploitable.
  int? get versionCode => int.tryParse(buildNumber);

  static Future<AppPackageInfo> fromPlatform() async {
    final raw = await _channel.invokeMapMethod<String, Object?>('get');
    final version = raw?['version']?.toString().trim() ?? '';
    final buildNumber = raw?['buildNumber']?.toString().trim() ?? '';
    if (version.isEmpty) {
      throw PlatformException(
        code: 'APP_INFO_UNAVAILABLE',
        message: 'Version Android indisponible.',
      );
    }
    return AppPackageInfo(
      version: version,
      buildNumber: buildNumber,
      packageName: raw?['packageName']?.toString().trim() ?? '',
    );
  }
}
