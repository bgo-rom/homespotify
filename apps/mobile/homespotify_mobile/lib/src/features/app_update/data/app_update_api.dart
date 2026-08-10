import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../domain/app_update_models.dart';

/// Client des routes publiques de mise à jour Android.
///
/// Il utilise un Dio DÉDIÉ, sans intercepteur d'authentification : une version
/// trop ancienne pour ouvrir une session doit tout de même pouvoir se mettre à
/// jour. Aucun jeton n'est donc envoyé sur ces deux routes.
class AppUpdateApi {
  AppUpdateApi(this._dio);

  final Dio _dio;

  /// Dernière version publiée, ou `null` si le serveur n'en publie aucune.
  /// Lève [AppUpdateException] quand le serveur est injoignable ou répond mal.
  Future<AndroidRelease?> fetchLatest({required int currentVersionCode}) async {
    final Response<dynamic> response;
    try {
      response = await _dio.get<dynamic>(
        '/api/app-update/android/latest',
        queryParameters: {'currentVersionCode': currentVersionCode},
        // Un 4xx/5xx applicatif est une RÉPONSE à interpréter, pas une panne
        // de transport : c'est ce qui distingue « pas de service de mise à
        // jour » (503) d'un serveur injoignable.
        options: Options(
          validateStatus: (status) => status != null && status < 600,
        ),
      );
    } on DioException catch (error) {
      throw AppUpdateException(
        'Serveur de mise à jour injoignable (${error.type.name}).',
      );
    }

    final status = response.statusCode ?? 0;
    if (status == 503) {
      // Le serveur ne publie pas de mises à jour : ce n'est pas une panne.
      return null;
    }
    if (status != 200) {
      throw AppUpdateException('Le serveur a répondu $status.');
    }

    final body = response.data;
    if (body is! Map) {
      throw AppUpdateException('Réponse de mise à jour illisible.');
    }
    final latest = body['latest'];
    if (latest == null) return null;
    final release = AndroidRelease.tryParse(latest);
    if (release == null) {
      throw AppUpdateException('Manifeste de mise à jour invalide.');
    }
    return release;
  }

  /// Ouvre le flux de téléchargement de l'APK, reprise possible par Range.
  Future<Response<ResponseBody>> openDownloadStream(
    String downloadPath, {
    int fromByte = 0,
    CancelToken? cancelToken,
  }) {
    return _dio.get<ResponseBody>(
      downloadPath,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.stream,
        // 60 s sans un seul octet reçu = connexion morte. Assez large pour un
        // réseau mobile lent, assez court pour ne pas figer l'écran.
        receiveTimeout: const Duration(seconds: 60),
        headers: fromByte > 0 ? {'Range': 'bytes=$fromByte-'} : null,
        validateStatus: (status) => status != null && status < 500,
      ),
    );
  }
}

/// Dio sans intercepteur d'authentification — cf. la note de classe.
final appUpdateDioProvider = Provider<Dio>((ref) => createApiClient());

final appUpdateApiProvider = Provider<AppUpdateApi>(
  (ref) => AppUpdateApi(ref.watch(appUpdateDioProvider)),
);
