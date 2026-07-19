import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';

enum NodeFetchJobStatus {
  queued('QUEUED'),
  fetching('FETCHING'),
  readyForImport('READY_FOR_IMPORT'),
  failed('FAILED');

  const NodeFetchJobStatus(this.wireName);
  final String wireName;

  static NodeFetchJobStatus parse(String value) {
    return NodeFetchJobStatus.values.firstWhere(
      (status) => status.wireName == value,
      orElse: () => NodeFetchJobStatus.failed,
    );
  }
}

class NodeFetchJob {
  const NodeFetchJob({
    required this.id,
    required this.status,
    this.bytesReceived = 0,
    this.filename,
    this.errorMessage,
  });

  factory NodeFetchJob.fromJson(Map<String, dynamic> json) {
    return NodeFetchJob(
      id: json['id'] as String? ?? '',
      status: NodeFetchJobStatus.parse(json['status'] as String? ?? ''),
      bytesReceived: (json['bytesReceived'] as num?)?.toInt() ?? 0,
      filename: json['filename'] as String?,
      errorMessage: json['errorMessage'] as String?,
    );
  }

  final String id;
  final NodeFetchJobStatus status;
  final int bytesReceived;
  final String? filename;
  final String? errorMessage;
}

class NodeFetchApiException implements Exception {
  const NodeFetchApiException(this.message);
  final String message;

  @override
  String toString() => message;
}

abstract interface class NodeFetchRepository {
  Future<NodeFetchJob> enqueue({required String url, required int userId});
  Future<NodeFetchJob> fetchJob(String jobId);
}

class NodeFetchApi implements NodeFetchRepository {
  NodeFetchApi(this._dio);

  final Dio _dio;

  @override
  Future<NodeFetchJob> enqueue({
    required String url,
    required int userId,
  }) async {
    final Response<Map<String, dynamic>> response;
    try {
      response = await _dio.post<Map<String, dynamic>>(
        '/api/library/fetch-node',
        data: <String, dynamic>{'url': url, 'userId': userId},
      );
    } on DioException catch (error) {
      throw NodeFetchApiException(_networkMessage(error));
    }
    final data = response.data;
    if (response.statusCode != 202 || data == null || data['job'] is! Map) {
      throw NodeFetchApiException(_responseMessage(response));
    }
    return NodeFetchJob.fromJson(Map<String, dynamic>.from(data['job'] as Map));
  }

  @override
  Future<NodeFetchJob> fetchJob(String jobId) async {
    final Response<Map<String, dynamic>> response;
    try {
      response = await _dio.get<Map<String, dynamic>>(
        '/api/library/fetch-node/$jobId',
      );
    } on DioException catch (error) {
      throw NodeFetchApiException(_networkMessage(error));
    }
    final data = response.data;
    if (response.statusCode != 200 || data == null || data['job'] is! Map) {
      throw NodeFetchApiException(_responseMessage(response));
    }
    return NodeFetchJob.fromJson(Map<String, dynamic>.from(data['job'] as Map));
  }

  String _responseMessage(Response<dynamic> response) {
    final data = response.data;
    if (data is Map && data['message'] is String) {
      return data['message'] as String;
    }
    return 'Le serveur a refusé l’import distant (${response.statusCode ?? '?'}).';
  }

  String _networkMessage(DioException error) {
    final responseData = error.response?.data;
    if (responseData is Map && responseData['message'] is String) {
      return responseData['message'] as String;
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

final nodeFetchApiProvider = Provider<NodeFetchRepository>((ref) {
  return NodeFetchApi(ref.watch(apiClientProvider));
});
