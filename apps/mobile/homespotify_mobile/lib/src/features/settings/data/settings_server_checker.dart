import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';

abstract interface class SettingsServerChecker {
  Future<void> checkHealth();
}

class DioSettingsServerChecker implements SettingsServerChecker {
  const DioSettingsServerChecker(this._dio);

  final Dio _dio;

  @override
  Future<void> checkHealth() async {
    final response = await _dio.get<Map<String, dynamic>>('/health');
    final isHealthy =
        response.statusCode == 200 && response.data?['status'] == 'ok';
    if (!isHealthy) {
      throw StateError(
        'Réponse de santé invalide (${response.statusCode ?? '?'}).',
      );
    }
  }
}

final settingsServerCheckerProvider = Provider<SettingsServerChecker>((ref) {
  return DioSettingsServerChecker(ref.watch(apiClientProvider));
});
