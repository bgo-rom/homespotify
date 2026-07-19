import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../library/domain/track.dart';

/// Erreur catalogue présentable à l'utilisateur.
class CatalogApiException implements Exception {
  const CatalogApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Entrée du CATALOGUE GLOBAL — strictement ANONYME.
///
/// Le backend ne renvoie aucune identité (importateur, demandeur, dossier) :
/// ce modèle ne peut donc pas en transporter. `inMyLibrary` ne concerne que le
/// compte appelant.
class CatalogEntry {
  const CatalogEntry({required this.track, required this.inMyLibrary});

  final Track track;
  final bool inMyLibrary;

  CatalogEntry copyWith({bool? inMyLibrary}) =>
      CatalogEntry(track: track, inMyLibrary: inMyLibrary ?? this.inMyLibrary);

  factory CatalogEntry.fromJson(Map<String, dynamic> json) => CatalogEntry(
    track: Track.fromJson(json),
    inMyLibrary: json['inMyLibrary'] as bool? ?? false,
  );
}

abstract interface class CatalogRepository {
  /// « Ajouts récents » du catalogue global (tous comptes, anonymisé).
  Future<List<CatalogEntry>> fetchRecent({int limit});

  /// Appartenance RÉELLE de la piste à la bibliothèque du compte courant
  /// (source d'autorité : `user_tracks`).
  Future<bool> isInMyLibrary(int trackId);

  /// Ajoute la piste à la bibliothèque du compte courant (idempotent).
  /// Retourne `true` si une association a été créée, `false` si elle existait
  /// déjà — dans les deux cas l'état final est « présente ».
  Future<bool> addToLibrary(int trackId);
}

class CatalogApi implements CatalogRepository {
  CatalogApi(this._dio);

  final Dio _dio;

  @override
  Future<List<CatalogEntry>> fetchRecent({int limit = 20}) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        '/api/catalog/recent',
        queryParameters: {'limit': limit},
      );
      final items = res.data?['items'] as List<dynamic>? ?? const [];
      return items
          .whereType<Map<String, dynamic>>()
          .map(CatalogEntry.fromJson)
          .toList(growable: false);
    } on DioException catch (error) {
      throw CatalogApiException(_message(error));
    }
  }

  @override
  Future<bool> isInMyLibrary(int trackId) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        '/api/library/tracks/$trackId',
      );
      _ensureOk(res.statusCode, res.data);
      return res.data?['inMyLibrary'] as bool? ?? false;
    } on DioException catch (error) {
      throw CatalogApiException(_message(error));
    }
  }

  @override
  Future<bool> addToLibrary(int trackId) async {
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '/api/library/tracks/$trackId',
      );
      _ensureOk(res.statusCode, res.data);
      return res.data?['added'] as bool? ?? true;
    } on DioException catch (error) {
      throw CatalogApiException(_message(error));
    }
  }

  /// ⚠️ `validateStatus: status < 500` : les 4xx ne lèvent pas d'exception Dio.
  /// On les transforme donc explicitement en erreur, sinon un échec passerait
  /// pour un succès.
  void _ensureOk(int? statusCode, Map<String, dynamic>? body) {
    final status = statusCode ?? 0;
    if (status >= 200 && status < 300) return;
    final message = body?['message'];
    throw CatalogApiException(
      message is String ? message : 'Opération refusée par le serveur.',
    );
  }

  String _message(DioException error) {
    final data = error.response?.data;
    if (data is Map<String, dynamic> && data['message'] is String) {
      return data['message'] as String;
    }
    return 'Le catalogue est momentanément indisponible.';
  }
}

final catalogApiProvider = Provider<CatalogRepository>(
  (ref) => CatalogApi(ref.watch(apiClientProvider)),
);

/// Ajouts récents du catalogue global. Contient `inMyLibrary` (propre au compte
/// courant) : ce provider DOIT être invalidé au logout — cf. AuthController.
final catalogRecentProvider = FutureProvider<List<CatalogEntry>>((ref) {
  return ref.watch(catalogApiProvider).fetchRecent(limit: 20);
});
