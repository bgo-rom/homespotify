import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../domain/track.dart';

/// Erreur bibliothèque présentable à l'utilisateur (message court, sans stack Dio).
class LibraryApiException implements Exception {
  LibraryApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Accès en lecture à la bibliothèque HomeSpotify + fabrique d'URLs média.
class LibraryApi {
  LibraryApi(this._dio, this._baseUrl);

  final Dio _dio;
  final String _baseUrl;

  Future<List<Track>> fetchTracks({int page = 1, int limit = 200}) async {
    final Response<Map<String, dynamic>> res;
    try {
      res = await _dio.get<Map<String, dynamic>>(
        '/api/tracks',
        queryParameters: {'page': page, 'limit': limit},
      );
    } on DioException catch (error) {
      throw LibraryApiException(_friendlyDioMessage(error));
    }

    final data = res.data;
    if (res.statusCode != 200 || data == null) {
      throw LibraryApiException(
        'Réponse invalide du serveur (${res.statusCode ?? '?'}).',
      );
    }
    final items = data['items'] as List<dynamic>? ?? const [];
    return items
        .whereType<Map<String, dynamic>>()
        .map(Track.fromJson)
        .toList(growable: false);
  }

  /// Suppression douce côté serveur : retire l'accès de CE compte (jamais le
  /// fichier physique), les favoris et occurrences de playlists associés, et
  /// masque la piste pour les futures recommandations.
  ///
  /// Retourne `true` si une suppression RÉELLE a eu lieu, `false` si la piste
  /// n'était pas dans la bibliothèque de ce compte (404). ⚠️ Le client Dio est
  /// configuré avec `validateStatus: status < 500` : un 404 ne lève PAS
  /// d'exception — il faut donc inspecter le statut, sinon on affiche un faux
  /// « supprimé » pour une piste jamais possédée.
  Future<bool> deleteTrack(int id) async {
    try {
      final res = await _dio.delete<dynamic>('/api/library/tracks/$id');
      final status = res.statusCode ?? 0;
      if (status == 404) return false;
      if (status >= 400) {
        throw LibraryApiException(_messageFromBody(res.data));
      }
      return true;
    } on DioException catch (error) {
      throw LibraryApiException(_friendlyDioMessage(error));
    }
  }

  String _messageFromBody(dynamic data) {
    if (data is Map && data['message'] is String) {
      return data['message'] as String;
    }
    return 'Opération refusée par le serveur.';
  }

  Uri streamUri(int id) => Uri.parse('$_baseUrl/api/tracks/$id/stream');

  Uri coverUri(int id) => Uri.parse('$_baseUrl/api/tracks/$id/cover');

  String _friendlyDioMessage(DioException error) {
    return switch (error.type) {
      DioExceptionType.connectionError || DioExceptionType.connectionTimeout =>
        '${AppConfig.serverUnreachableMessage} '
            'Vérifie que l\'API tourne et l\'adresse ($_baseUrl).',
      DioExceptionType.receiveTimeout || DioExceptionType.sendTimeout =>
        'Le serveur met trop de temps à répondre.',
      DioExceptionType.badCertificate => 'Certificat refusé par le serveur.',
      DioExceptionType.badResponse =>
        'Le serveur a répondu une erreur (${error.response?.statusCode ?? '?'}).',
      _ => 'Échec de la requête bibliothèque (${error.type.name}).',
    };
  }
}

final libraryApiProvider = Provider<LibraryApi>((ref) {
  return LibraryApi(ref.watch(apiClientProvider), homespotifyApiBaseUrl);
});

/// Charge la bibliothèque. `ref.invalidate(libraryProvider)` pour réessayer.
final libraryProvider = FutureProvider<List<Track>>((ref) {
  return ref.watch(libraryApiProvider).fetchTracks();
});
