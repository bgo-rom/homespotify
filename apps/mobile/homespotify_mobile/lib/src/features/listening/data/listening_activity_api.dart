import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../domain/listening_activity.dart';

class ListeningActivityApiException implements Exception {
  const ListeningActivityApiException(this.message);
  final String message;
}

class ListeningActivityApi {
  const ListeningActivityApi(this._dio);
  final Dio _dio;

  Future<void> sendBatch(List<Map<String, dynamic>> events) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/api/play-events/batch',
      data: {'events': events},
    );
    if (response.statusCode != 201) {
      throw ListeningActivityApiException(
        'Envoi différé (${response.statusCode ?? '?'})',
      );
    }
  }

  Future<ListeningActivityPage> fetchActivity({String? cursor}) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/api/me/listening-activity',
      queryParameters: {'limit': 20, 'cursor': ?cursor},
    );
    final data = response.data;
    if (response.statusCode != 200 || data == null) {
      throw const ListeningActivityApiException(
        'L’activité d’écoute est indisponible.',
      );
    }
    return ListeningActivityPage(
      items: (data['items'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ListeningSession.fromJson)
          .toList(growable: false),
      nextCursor: data['nextCursor'] as String?,
    );
  }

  Future<List<ResumeListeningItem>> fetchResume() async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/api/me/resume-listening',
    );
    final data = response.data;
    if (response.statusCode != 200 || data == null) {
      throw const ListeningActivityApiException(
        'La reprise d’écoute est indisponible.',
      );
    }
    return (data['items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(ResumeListeningItem.fromJson)
        .toList(growable: false);
  }

  Future<void> clearActivity() async {
    final response = await _dio.delete<void>('/api/me/listening-activity');
    if (response.statusCode != 204) {
      throw const ListeningActivityApiException(
        'L’historique n’a pas pu être supprimé.',
      );
    }
  }
}

final listeningActivityApiProvider = Provider<ListeningActivityApi>((ref) {
  return ListeningActivityApi(ref.watch(apiClientProvider));
});

final resumeListeningProvider = FutureProvider<List<ResumeListeningItem>>((
  ref,
) {
  return ref.watch(listeningActivityApiProvider).fetchResume();
});

final listeningActivityProvider = FutureProvider<ListeningActivityPage>((ref) {
  return ref.watch(listeningActivityApiProvider).fetchActivity();
});
