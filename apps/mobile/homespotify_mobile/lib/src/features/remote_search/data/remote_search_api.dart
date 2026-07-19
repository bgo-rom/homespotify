import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../node_fetch/data/node_fetch_api.dart';
import '../domain/remote_track.dart';

class RemoteSearchApiException implements Exception {
  const RemoteSearchApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract interface class RemoteSearchRepository {
  Future<List<RemoteTrack>> search(String query);
  Future<NodeFetchJob> importTrack(String trackId);
  Future<NodeFetchJob> fetchImportJob(String jobId);
}

class RemoteSearchApi implements RemoteSearchRepository {
  RemoteSearchApi(this._dio);

  final Dio _dio;

  @override
  Future<List<RemoteTrack>> search(String query) async {
    final response = await _request(
      () => _dio.get<Map<String, dynamic>>(
        '/api/library/search-remote',
        queryParameters: <String, dynamic>{'q': query},
      ),
    );
    final rawResults = response.data?['results'];
    if (response.statusCode != 200 || rawResults is! List) {
      throw const RemoteSearchApiException(
        'Réponse de recherche distante invalide.',
      );
    }
    return rawResults
        .whereType<Map>()
        .map((json) => RemoteTrack.fromJson(Map<String, dynamic>.from(json)))
        .where((track) => track.trackId.isNotEmpty)
        .toList(growable: false);
  }

  @override
  Future<NodeFetchJob> importTrack(String trackId) async {
    final response = await _request(
      () => _dio.post<Map<String, dynamic>>(
        '/api/library/import-remote-track',
        data: <String, dynamic>{'trackId': trackId},
      ),
    );
    final data = response.data;
    if (response.statusCode != 202 || data == null || data['job'] is! Map) {
      throw const RemoteSearchApiException(
        'Le serveur a refusé l’import de cette piste.',
      );
    }
    return NodeFetchJob.fromJson(Map<String, dynamic>.from(data['job'] as Map));
  }

  @override
  Future<NodeFetchJob> fetchImportJob(String jobId) async {
    final response = await _request(
      () => _dio.get<Map<String, dynamic>>(
        '/api/library/import-remote-track/$jobId',
      ),
    );
    final data = response.data;
    if (response.statusCode != 200 || data == null || data['job'] is! Map) {
      throw const RemoteSearchApiException(
        'État de l’import distant invalide.',
      );
    }
    return NodeFetchJob.fromJson(Map<String, dynamic>.from(data['job'] as Map));
  }

  Future<Response<T>> _request<T>(
    Future<Response<T>> Function() request,
  ) async {
    try {
      return await request();
    } on DioException catch (error) {
      throw RemoteSearchApiException(_networkMessage(error));
    }
  }

  String _networkMessage(DioException error) {
    final data = error.response?.data;
    if (data is Map && data['message'] is String) {
      return data['message'] as String;
    }
    return switch (error.type) {
      DioExceptionType.connectionError ||
      DioExceptionType.connectionTimeout => 'Serveur HomeSpotify inaccessible.',
      DioExceptionType.receiveTimeout || DioExceptionType.sendTimeout =>
        'Le serveur met trop de temps à répondre.',
      DioExceptionType.badCertificate => 'Certificat du serveur refusé.',
      _ => 'Impossible de contacter le serveur HomeSpotify.',
    };
  }
}

final remoteSearchApiProvider = Provider<RemoteSearchRepository>((ref) {
  return RemoteSearchApi(ref.watch(apiClientProvider));
});
