import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_diagnostics.dart';

const _enabledPreferenceKey = 'replay_gain_enabled_v1';
const _cachePrefix = 'replay_gain_measurement_v1_';

enum ReplayGainPhase { disabled, idle, analyzing, applied, unavailable, error }

class ReplayGainAnalysis {
  const ReplayGainAnalysis({
    required this.trackId,
    required this.status,
    this.integratedLufs,
    this.truePeakDbfs,
    this.replayGainDb,
    this.targetLufs = -18,
    this.peakCeilingDbfs = -1,
    this.failureReason,
  });

  final int trackId;
  final String status;
  final double? integratedLufs;
  final double? truePeakDbfs;
  final double? replayGainDb;
  final double targetLufs;
  final double peakCeilingDbfs;
  final String? failureReason;

  bool get isPending => status == 'PENDING' || status == 'ANALYZING';

  bool get isReady =>
      status == 'READY' &&
      integratedLufs != null &&
      truePeakDbfs != null &&
      replayGainDb != null;

  factory ReplayGainAnalysis.fromJson(Map<String, dynamic> json) {
    final analysis = ReplayGainAnalysis(
      trackId: (json['trackId'] as num).toInt(),
      status: json['status'] as String? ?? 'PENDING',
      integratedLufs: (json['integratedLufs'] as num?)?.toDouble(),
      truePeakDbfs: (json['truePeakDbfs'] as num?)?.toDouble(),
      replayGainDb: (json['replayGainDb'] as num?)?.toDouble(),
      targetLufs: (json['targetLufs'] as num?)?.toDouble() ?? -18,
      peakCeilingDbfs: (json['peakCeilingDbfs'] as num?)?.toDouble() ?? -1,
      failureReason: json['failureReason'] as String?,
    );
    if (analysis.isReady && !analysis.hasValidMeasurement) {
      throw const FormatException('Mesure ReplayGain hors limites.');
    }
    return analysis;
  }

  bool get hasValidMeasurement =>
      integratedLufs != null &&
      integratedLufs!.isFinite &&
      integratedLufs! >= -70 &&
      integratedLufs! <= 5 &&
      truePeakDbfs != null &&
      truePeakDbfs!.isFinite &&
      truePeakDbfs! >= -120 &&
      truePeakDbfs! <= 20 &&
      replayGainDb != null &&
      replayGainDb!.isFinite &&
      replayGainDb! >= -24 &&
      replayGainDb! <= 12;

  Map<String, Object?> toJson() => {
    'trackId': trackId,
    'status': status,
    'integratedLufs': integratedLufs,
    'truePeakDbfs': truePeakDbfs,
    'replayGainDb': replayGainDb,
    'targetLufs': targetLufs,
    'peakCeilingDbfs': peakCeilingDbfs,
    'failureReason': failureReason,
  };
}

class ReplayGainState {
  const ReplayGainState({
    required this.enabled,
    required this.phase,
    this.trackId,
    this.analysis,
    this.message,
  });

  const ReplayGainState.disabled()
    : enabled = false,
      phase = ReplayGainPhase.disabled,
      trackId = null,
      analysis = null,
      message = null;

  final bool enabled;
  final ReplayGainPhase phase;
  final int? trackId;
  final ReplayGainAnalysis? analysis;
  final String? message;

  double? get appliedGainDb =>
      phase == ReplayGainPhase.applied ? analysis?.replayGainDb : null;
}

abstract interface class ReplayGainRepository {
  Future<bool> loadEnabled();
  Future<void> saveEnabled(bool enabled);
  Future<ReplayGainAnalysis> resolve(int trackId);
}

class CachedReplayGainRepository implements ReplayGainRepository {
  CachedReplayGainRepository(this._dio, this._preferences);

  CachedReplayGainRepository.withDefaults(Dio dio)
    : this(dio, SharedPreferencesAsync());

  final Dio _dio;
  final SharedPreferencesAsync _preferences;

  @override
  Future<bool> loadEnabled() async =>
      await _preferences.getBool(_enabledPreferenceKey) ?? false;

  @override
  Future<void> saveEnabled(bool enabled) =>
      _preferences.setBool(_enabledPreferenceKey, enabled);

  @override
  Future<ReplayGainAnalysis> resolve(int trackId) async {
    ReplayGainAnalysis? cached;
    try {
      cached = await _readCached(trackId);
    } catch (_) {
      await _preferences.remove('$_cachePrefix$trackId');
    }

    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/api/tracks/$trackId/loudness-analysis',
      );
      final data = response.data;
      final status = response.statusCode ?? 0;
      if (status < 200 || status >= 300 || data == null) {
        throw StateError('Réponse R128 invalide ($status).');
      }
      final analysis = ReplayGainAnalysis.fromJson(data);
      if (analysis.isReady) {
        await _preferences.setString(
          '$_cachePrefix$trackId',
          jsonEncode(analysis.toJson()),
        );
        return analysis;
      }
      return cached ?? analysis;
    } on DioException {
      if (cached != null) return cached;
      rethrow;
    }
  }

  Future<ReplayGainAnalysis?> _readCached(int trackId) async {
    final raw = await _preferences.getString('$_cachePrefix$trackId');
    if (raw == null) return null;
    final json = jsonDecode(raw);
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Cache ReplayGain invalide.');
    }
    final analysis = ReplayGainAnalysis.fromJson(json);
    return analysis.isReady ? analysis : null;
  }
}

abstract interface class ReplayGainEngine {
  Future<void> applyGainDb(double? gainDb);
}

class AndroidReplayGainEngine implements ReplayGainEngine {
  const AndroidReplayGainEngine(
    this._enhancer, {
    required this._attenuationApplier,
  });

  final AndroidLoudnessEnhancer _enhancer;
  final Future<void> Function(double? gainDb) _attenuationApplier;

  @override
  Future<void> applyGainDb(double? gainDb) async {
    if (gainDb == null) {
      await _enhancer.setEnabled(false);
      await _enhancer.setTargetGain(0);
      await _attenuationApplier(null);
      return;
    }
    final safeGain = gainDb.clamp(-24.0, 12.0).toDouble();
    if (safeGain < 0) {
      await _enhancer.setEnabled(false);
      await _enhancer.setTargetGain(0);
      await _attenuationApplier(safeGain);
    } else {
      await _enhancer.setEnabled(false);
      await _attenuationApplier(null);
      await _enhancer.setTargetGain(safeGain);
      await _enhancer.setEnabled(true);
    }
  }
}

class ReplayGainController {
  ReplayGainController({
    required ReplayGainRepository repository,
    required ReplayGainEngine engine,
    required Stream<MediaItem?> mediaItems,
    Duration pollInterval = const Duration(seconds: 3),
    int maxPollAttempts = 20,
  }) : this._(repository, engine, mediaItems, pollInterval, maxPollAttempts);

  ReplayGainController._(
    this._repository,
    this._engine,
    this._mediaItems,
    this._pollInterval,
    this._maxPollAttempts,
  );

  factory ReplayGainController.disabled() => ReplayGainController(
    repository: _DisabledReplayGainRepository(),
    engine: _NoopReplayGainEngine(),
    mediaItems: const Stream<MediaItem?>.empty(),
    maxPollAttempts: 0,
  );

  final ReplayGainRepository _repository;
  final ReplayGainEngine _engine;
  final Stream<MediaItem?> _mediaItems;
  final Duration _pollInterval;
  final int _maxPollAttempts;
  final ValueNotifier<ReplayGainState> state = ValueNotifier(
    const ReplayGainState.disabled(),
  );

  StreamSubscription<MediaItem?>? _mediaSubscription;
  int _request = 0;
  int? _currentTrackId;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    var enabled = false;
    try {
      enabled = await _repository.loadEnabled();
    } catch (error) {
      AudioDiagnostics.instance.log('REPLAY_GAIN_PREFERENCE_READ_FAILED', {
        'errorClass': error.runtimeType,
      });
    }
    state.value = ReplayGainState(
      enabled: enabled,
      phase: enabled ? ReplayGainPhase.idle : ReplayGainPhase.disabled,
    );
    await _engine.applyGainDb(null);
    _mediaSubscription = _mediaItems
        .distinct((previous, next) => previous?.id == next?.id)
        .listen(_onMediaItem);
  }

  Future<void> setEnabled(bool enabled) async {
    if (!_initialized) await initialize();
    try {
      await _repository.saveEnabled(enabled);
    } catch (error) {
      state.value = ReplayGainState(
        enabled: state.value.enabled,
        phase: ReplayGainPhase.error,
        trackId: _currentTrackId,
        message: 'Le réglage n’a pas pu être enregistré.',
      );
      rethrow;
    }

    final request = ++_request;
    state.value = ReplayGainState(
      enabled: enabled,
      phase: enabled ? ReplayGainPhase.idle : ReplayGainPhase.disabled,
      trackId: _currentTrackId,
    );
    await _engine.applyGainDb(null);
    AudioDiagnostics.instance.log(
      enabled ? 'REPLAY_GAIN_ENABLED' : 'REPLAY_GAIN_DISABLED',
    );
    if (enabled && _currentTrackId != null) {
      unawaited(_resolveAndApply(_currentTrackId!, request));
    }
  }

  void _onMediaItem(MediaItem? item) {
    final trackId = item == null ? null : int.tryParse(item.id);
    _currentTrackId = trackId;
    final request = ++_request;
    final enabled = state.value.enabled;
    state.value = ReplayGainState(
      enabled: enabled,
      phase: enabled ? ReplayGainPhase.idle : ReplayGainPhase.disabled,
      trackId: trackId,
    );
    unawaited(_resetThenResolve(trackId, request, enabled));
  }

  Future<void> _resetThenResolve(
    int? trackId,
    int request,
    bool enabled,
  ) async {
    try {
      await _engine.applyGainDb(null);
    } catch (error) {
      if (request != _request) return;
      state.value = ReplayGainState(
        enabled: enabled,
        phase: enabled ? ReplayGainPhase.unavailable : ReplayGainPhase.disabled,
        trackId: trackId,
        message: enabled
            ? 'Normalisation indisponible sur cet appareil.'
            : null,
      );
      AudioDiagnostics.instance.log('REPLAY_GAIN_RESET_FAILED', {
        'trackId': trackId == null ? null : '$trackId',
        'errorClass': error.runtimeType,
      });
      return;
    }
    if (enabled &&
        trackId != null &&
        request == _request &&
        _currentTrackId == trackId) {
      await _resolveAndApply(trackId, request);
    }
  }

  Future<void> _resolveAndApply(int trackId, int request) async {
    for (var attempt = 0; attempt <= _maxPollAttempts; attempt += 1) {
      if (!_isCurrent(request, trackId)) return;
      try {
        final analysis = await _repository.resolve(trackId);
        if (!_isCurrent(request, trackId)) return;
        if (analysis.isReady) {
          await _engine.applyGainDb(analysis.replayGainDb);
          if (!_isCurrent(request, trackId)) {
            await _engine.applyGainDb(null);
            return;
          }
          state.value = ReplayGainState(
            enabled: true,
            phase: ReplayGainPhase.applied,
            trackId: trackId,
            analysis: analysis,
          );
          AudioDiagnostics.instance.log('REPLAY_GAIN_APPLIED', {
            'trackId': '$trackId',
            'gainDb': analysis.replayGainDb,
            'integratedLufs': analysis.integratedLufs,
            'truePeakDbfs': analysis.truePeakDbfs,
          });
          return;
        }
        if (!analysis.isPending) {
          state.value = ReplayGainState(
            enabled: true,
            phase: ReplayGainPhase.unavailable,
            trackId: trackId,
            analysis: analysis,
            message: 'Mesure indisponible pour ce titre.',
          );
          return;
        }
        state.value = ReplayGainState(
          enabled: true,
          phase: ReplayGainPhase.analyzing,
          trackId: trackId,
          analysis: analysis,
        );
      } catch (error) {
        if (!_isCurrent(request, trackId)) return;
        state.value = ReplayGainState(
          enabled: true,
          phase: ReplayGainPhase.unavailable,
          trackId: trackId,
          message: 'Mesure indisponible hors connexion.',
        );
        AudioDiagnostics.instance.log('REPLAY_GAIN_RESOLUTION_FAILED', {
          'trackId': '$trackId',
          'errorClass': error.runtimeType,
        });
        return;
      }
      if (attempt == _maxPollAttempts) {
        state.value = ReplayGainState(
          enabled: true,
          phase: ReplayGainPhase.unavailable,
          trackId: trackId,
          message: 'Analyse toujours en attente.',
        );
        return;
      }
      await Future<void>.delayed(_pollInterval);
    }
  }

  bool _isCurrent(int request, int trackId) =>
      request == _request && state.value.enabled && _currentTrackId == trackId;

  Future<void> dispose() async {
    ++_request;
    await _mediaSubscription?.cancel();
    await _engine.applyGainDb(null);
    state.dispose();
  }
}

class _DisabledReplayGainRepository implements ReplayGainRepository {
  @override
  Future<bool> loadEnabled() async => false;

  @override
  Future<ReplayGainAnalysis> resolve(int trackId) async =>
      ReplayGainAnalysis(trackId: trackId, status: 'FAILED');

  @override
  Future<void> saveEnabled(bool enabled) async {}
}

class _NoopReplayGainEngine implements ReplayGainEngine {
  @override
  Future<void> applyGainDb(double? gainDb) async {}
}

final replayGainControllerProvider = Provider<ReplayGainController>(
  (ref) => ReplayGainController.disabled(),
);
