import 'dart:developer' as developer;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';

class TrackPlaybackSettings {
  const TrackPlaybackSettings({
    required this.trackId,
    required this.speedRatio,
    required this.preservePitch,
    required this.isDefault,
  });

  final int trackId;
  final double speedRatio;
  final bool preservePitch;
  final bool isDefault;

  factory TrackPlaybackSettings.fromJson(Map<String, dynamic> json) {
    return TrackPlaybackSettings(
      trackId: (json['trackId'] as num).toInt(),
      speedRatio: (json['speedRatio'] as num?)?.toDouble() ?? 1,
      preservePitch: json['preservePitch'] == true,
      isDefault: json['isDefault'] == true,
    );
  }
}

class TrackAudioAnalysis {
  const TrackAudioAnalysis({
    required this.trackId,
    required this.status,
    this.bpm,
    this.confidence,
    this.source,
    this.failureReason,
  });

  final int trackId;
  final String status;
  final double? bpm;
  final double? confidence;
  final String? source;
  final String? failureReason;

  bool get isApproximate => confidence != null && confidence! < 0.75;

  bool get isPending => status == 'PENDING' || status == 'ANALYZING';

  bool get isTerminal =>
      status == 'READY' || status == 'LOW_CONFIDENCE' || status == 'FAILED';

  factory TrackAudioAnalysis.fromJson(Map<String, dynamic> json) {
    return TrackAudioAnalysis(
      trackId: (json['trackId'] as num).toInt(),
      status: json['status'] as String? ?? 'PENDING',
      bpm: (json['bpm'] as num?)?.toDouble(),
      confidence: (json['bpmConfidence'] as num?)?.toDouble(),
      source: json['bpmSource'] as String?,
      failureReason: json['failureReason'] as String?,
    );
  }
}

class PlaybackSettingsApiException implements Exception {
  const PlaybackSettingsApiException({required this.message, this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

abstract interface class PlaybackSettingsRepository {
  Future<TrackPlaybackSettings> fetch(int trackId);
  Future<TrackPlaybackSettings> save(int trackId, double speedRatio);
  Future<void> reset(int trackId);
  Future<TrackAudioAnalysis> fetchAnalysis(int trackId);
}

class PlaybackSettingsApi implements PlaybackSettingsRepository {
  PlaybackSettingsApi(this._dio);

  final Dio _dio;

  @override
  Future<TrackPlaybackSettings> fetch(int trackId) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/api/tracks/$trackId/playback-settings',
    );
    return TrackPlaybackSettings.fromJson(_requireSuccess(response));
  }

  @override
  Future<TrackPlaybackSettings> save(int trackId, double speedRatio) async {
    final body = <String, Object>{
      'speedRatio': speedRatio,
      'preservePitch': true,
    };
    _debugApiLog(
      'PUT playback-settings track=$trackId body=$body '
      'ratioType=${speedRatio.runtimeType}',
    );
    try {
      final response = await _dio.put<Map<String, dynamic>>(
        '/api/tracks/$trackId/playback-settings',
        data: body,
      );
      final data = _requireSuccess(response);
      _debugApiLog(
        'PUT playback-settings track=$trackId http=${response.statusCode} '
        'saved=${data['speedRatio']}',
      );
      return TrackPlaybackSettings.fromJson(data);
    } on DioException catch (error, stackTrace) {
      throw _mapDioError(
        error,
        stackTrace,
        operation: 'PUT playback-settings track=$trackId',
      );
    }
  }

  @override
  Future<void> reset(int trackId) async {
    final response = await _dio.delete<void>(
      '/api/tracks/$trackId/playback-settings',
    );
    if (response.statusCode != 204) {
      throw StateError(
        'Réinitialisation de vitesse refusée (${response.statusCode}).',
      );
    }
  }

  @override
  Future<TrackAudioAnalysis> fetchAnalysis(int trackId) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/api/tracks/$trackId/audio-analysis',
      );
      return TrackAudioAnalysis.fromJson(_requireSuccess(response));
    } on DioException catch (error, stackTrace) {
      throw _mapDioError(
        error,
        stackTrace,
        operation: 'GET audio-analysis track=$trackId',
      );
    }
  }

  Map<String, dynamic> _requireSuccess(
    Response<Map<String, dynamic>> response,
  ) {
    final status = response.statusCode ?? 0;
    final data = response.data;
    if (status < 200 || status >= 300 || data == null) {
      final message = data?['message'];
      throw StateError(
        message is String
            ? message
            : 'Réponse de réglage audio invalide ($status).',
      );
    }
    return data;
  }

  PlaybackSettingsApiException _mapDioError(
    DioException error,
    StackTrace stackTrace, {
    required String operation,
  }) {
    final status = error.response?.statusCode;
    final data = error.response?.data;
    final backendMessage = data is Map<String, dynamic>
        ? data['message']
        : null;
    final message = backendMessage is String
        ? backendMessage
        : status == null
        ? 'Le serveur audio est indisponible.'
        : 'Le serveur a refusé le réglage audio ($status).';
    _debugApiLog(
      '$operation http=${status ?? 'aucun'} réponse=${_safeResponse(data)}',
      error: error,
      stackTrace: stackTrace,
    );
    return PlaybackSettingsApiException(message: message, statusCode: status);
  }
}

void _debugApiLog(String message, {Object? error, StackTrace? stackTrace}) {
  if (!kDebugMode) return;
  developer.log(
    message,
    name: 'homespotify.playback-settings',
    error: error,
    stackTrace: stackTrace,
  );
}

Object? _safeResponse(Object? data) {
  if (data is! Map) return data;
  return <String, Object?>{
    if (data['statusCode'] != null) 'statusCode': data['statusCode'],
    if (data['error'] != null) 'error': data['error'],
    if (data['message'] != null) 'message': data['message'],
  };
}

final playbackSettingsRepositoryProvider = Provider<PlaybackSettingsRepository>(
  (ref) => PlaybackSettingsApi(ref.watch(apiClientProvider)),
);
