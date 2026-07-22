import 'package:flutter/services.dart';

class AppPackageInfo {
  const AppPackageInfo({required this.version, required this.buildNumber});

  static const MethodChannel _channel = MethodChannel(
    'com.homespotify/app_info',
  );

  final String version;
  final String buildNumber;

  String get displayVersion =>
      buildNumber.isEmpty ? version : '$version+$buildNumber';

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
    return AppPackageInfo(version: version, buildNumber: buildNumber);
  }
}
