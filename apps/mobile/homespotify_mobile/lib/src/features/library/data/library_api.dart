import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  Uri streamUri(int id) => Uri.parse('$_baseUrl/api/tracks/$id/stream');

  Uri coverUri(int id) => Uri.parse('$_baseUrl/api/tracks/$id/cover');

  String _friendlyDioMessage(DioException error) {
    return switch (error.type) {
      DioExceptionType.connectionError || DioExceptionType.connectionTimeout =>
        'Serveur injoignable. Vérifie que l\'API tourne et l\'adresse ($_baseUrl), '
            'et que le HTTP local est autorisé.',
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
