import 'dart:async';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/logging/app_logger.dart';
import '../../player/audio/homespotify_audio_handler.dart';
import '../data/listening_activity_api.dart';
import '../data/listening_event_store.dart';

typedef MonotonicMilliseconds = int Function();

abstract interface class ListeningPlaybackSource {
  Stream<MediaItem?> get mediaItems;
  Stream<PlaybackState> get playbackStates;
  Stream<PlayerPositionData> get positions;
}

class AudioHandlerListeningSource implements ListeningPlaybackSource {
  const AudioHandlerListeningSource(this._handler);
  final HomeSpotifyAudioHandler _handler;

  @override
  Stream<MediaItem?> get mediaItems => _handler.mediaItem;
  @override
  Stream<PlaybackState> get playbackStates => _handler.playbackState;
  @override
  Stream<PlayerPositionData> get positions => _handler.positionDataStream;
}

final listeningEventStoreProvider = Provider<ListeningEventStore>((ref) {
  return SqliteListeningEventStore();
});

final listeningActivityTrackerProvider =
    Provider.family<ListeningActivityTracker, int>((ref, userId) {
      final tracker = ListeningActivityTracker(
        userId: userId,
        playback: AudioHandlerListeningSource(ref.watch(audioHandlerProvider)),
        api: ref.watch(listeningActivityApiProvider),
        store: ref.watch(listeningEventStoreProvider),
      );
      tracker.start();
      ref.onDispose(tracker.dispose);
      return tracker;
    });

/// Observateur best-effort : aucune de ses erreurs ne remonte vers le lecteur.
/// La durée est calculée avec une horloge monotone et non avec la position média.
class ListeningActivityTracker with WidgetsBindingObserver {
  ListeningActivityTracker({
    required this.userId,
    required this.playback,
    required this.api,
    required this.store,
    MonotonicMilliseconds? monotonicMilliseconds,
    DateTime Function()? clock,
  }) : _monotonicMilliseconds =
           monotonicMilliseconds ?? (() => _stopwatch.elapsedMilliseconds),
       _clock = clock ?? DateTime.now;

  final int userId;
  final ListeningPlaybackSource playback;
  final ListeningActivityApi api;
  final ListeningEventStore store;
  final MonotonicMilliseconds _monotonicMilliseconds;
  final DateTime Function() _clock;

  static final Stopwatch _stopwatch = Stopwatch()..start();
  static const _installationKey = 'homespotify_installation_id';
  static const _heartbeatMs = 30_000;

  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Timer? _tickTimer;
  Timer? _retryTimer;
  Future<void>? _sendInFlight;
  bool _disposed = false;
  bool _playing = false;
  bool _started = false;
  String? _installationId;
  String? _sessionId;
  int? _trackId;
  int _listenedMs = 0;
  int _lastProgressMs = 0;
  int _lastAccrualAt = 0;
  int _positionMs = 0;
  int _durationMs = 0;
  int? _lastObservedPositionMs;
  int? _lastObservedAt;
  int _lastSeekEventAt = -10000;
  double _speed = 1;
  int _retryAttempt = 0;
  String? _lastTerminalSessionId;

  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _subscriptions
      ..add(playback.mediaItems.listen(_onMediaItem, onError: _ignoreError))
      ..add(
        playback.playbackStates.listen(_onPlaybackState, onError: _ignoreError),
      )
      ..add(playback.positions.listen(_onPosition, onError: _ignoreError));
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    unawaited(_initializeAndFlush().catchError(_ignoreAsyncError));
  }

  Future<void> _initializeAndFlush() async {
    final preferences = await SharedPreferences.getInstance();
    var installationId = preferences.getString(_installationKey);
    if (installationId == null || installationId.isEmpty) {
      installationId = _uuid();
      await preferences.setString(_installationKey, installationId);
    }
    if (_disposed) return;
    _installationId = installationId;
    if (_playing) _openSessionIfNeeded();
    await _flushPending();
  }

  void _onMediaItem(MediaItem? item) {
    final nextTrackId = item == null ? null : int.tryParse(item.id);
    if (_trackId != null && nextTrackId != _trackId && _sessionId != null) {
      _accrue();
      _queueEvent('PLAY_SKIPPED', terminal: true);
    }
    _trackId = nextTrackId;
    _positionMs = 0;
    _durationMs = item?.duration?.inMilliseconds ?? 0;
    _lastObservedPositionMs = null;
    _lastObservedAt = null;
    if (nextTrackId != null && _playing) _openSessionIfNeeded();
  }

  void _onPlaybackState(PlaybackState state) {
    _speed = state.speed.clamp(0.7, 1.3);
    final completed = state.processingState == AudioProcessingState.completed;
    final failed = state.processingState == AudioProcessingState.error;
    final isActuallyPlaying =
        state.playing && state.processingState == AudioProcessingState.ready;
    if (completed && _sessionId != null) {
      _accrue();
      _queueEvent('PLAY_COMPLETED', terminal: true);
    }
    if (failed && _sessionId != null) {
      _accrue();
      _queueEvent('PLAY_ERROR', terminal: true);
    }
    if (isActuallyPlaying == _playing) return;
    _playing = isActuallyPlaying;
    if (_playing) {
      _lastAccrualAt = _monotonicMilliseconds();
      if (_sessionId == null) {
        _openSessionIfNeeded();
      } else {
        _queueEvent('PLAY_RESUMED');
      }
    } else if (_sessionId != null && !completed && !failed) {
      _accrue();
      _queueEvent('PLAY_PAUSED');
    }
  }

  void _onPosition(PlayerPositionData data) {
    final nextPosition = max(0, data.position.inMilliseconds);
    final now = _monotonicMilliseconds();
    final previousPosition = _lastObservedPositionMs;
    final previousAt = _lastObservedAt;
    if (_playing &&
        _sessionId != null &&
        previousPosition != null &&
        previousAt != null) {
      final wallDelta = now - previousAt;
      final mediaDelta = nextPosition - previousPosition;
      final expectedDelta = wallDelta * _speed;
      if (wallDelta >= 0 &&
          wallDelta <= 2000 &&
          now - _lastSeekEventAt >= 2000 &&
          (mediaDelta < -2000 || mediaDelta > expectedDelta + 4000)) {
        _positionMs = nextPosition;
        _lastSeekEventAt = now;
        _queueEvent('PLAY_SEEKED');
      }
    }
    _positionMs = nextPosition;
    _durationMs = max(0, data.duration.inMilliseconds);
    _lastObservedPositionMs = nextPosition;
    _lastObservedAt = now;
  }

  void _openSessionIfNeeded() {
    final trackId = _trackId;
    if (_sessionId != null || trackId == null || _installationId == null) {
      return;
    }
    _sessionId = _uuid();
    _listenedMs = 0;
    _lastProgressMs = 0;
    _lastAccrualAt = _monotonicMilliseconds();
    _lastTerminalSessionId = null;
    _queueEvent('PLAY_STARTED');
    logAudioAction('LISTENING_SESSION_STARTED track=$trackId');
  }

  void _tick() {
    if (!_playing || _sessionId == null) return;
    _accrue();
    if (_listenedMs - _lastProgressMs >= _heartbeatMs) {
      _lastProgressMs = _listenedMs;
      _queueEvent('PLAY_PROGRESS');
    }
  }

  void _accrue() {
    final now = _monotonicMilliseconds();
    if (_playing && _sessionId != null && _lastAccrualAt >= 0) {
      final delta = now - _lastAccrualAt;
      if (delta > 0 && delta < 10_000) _listenedMs += delta;
    }
    _lastAccrualAt = now;
  }

  void _queueEvent(String type, {bool terminal = false}) {
    final sessionId = _sessionId;
    final installationId = _installationId;
    final trackId = _trackId;
    if (sessionId == null ||
        installationId == null ||
        trackId == null ||
        (terminal && _lastTerminalSessionId == sessionId)) {
      return;
    }
    if (terminal) _lastTerminalSessionId = sessionId;
    final payload = <String, dynamic>{
      'clientEventId': _uuid(),
      'clientSessionId': sessionId,
      'installationId': installationId,
      'trackId': trackId,
      'type': type,
      'positionMs': _positionMs,
      'listenedMs': _listenedMs,
      if (_durationMs > 0) 'durationMs': _durationMs,
      'playbackSpeed': (_speed * 100).round() / 100,
      'clientCreatedAt': _clock().toUtc().toIso8601String(),
    };
    unawaited(_persistAndFlush(payload).catchError(_ignoreAsyncError));
    if (terminal) {
      _sessionId = null;
      _listenedMs = 0;
      _lastProgressMs = 0;
    }
  }

  Future<void> _persistAndFlush(Map<String, dynamic> payload) async {
    await store.enqueue(userId, payload);
    await _flushPending();
  }

  Future<void> _flushPending() {
    if (_disposed) return Future.value();
    final current = _sendInFlight;
    if (current != null) return current;
    final future = _sendPending().whenComplete(() => _sendInFlight = null);
    _sendInFlight = future;
    return future;
  }

  Future<void> _sendPending() async {
    final pending = await store.pending(userId);
    if (pending.isEmpty || _disposed) return;
    try {
      await api.sendBatch(
        pending.map((event) => event.payload).toList(growable: false),
      );
      await store.acknowledge(pending.map((event) => event.id));
      _retryAttempt = 0;
      logAudioAction('LISTENING_BATCH_ACCEPTED count=${pending.length}');
      if (!_disposed) unawaited(_flushPending().catchError(_ignoreAsyncError));
    } catch (error) {
      _retryAttempt = min(_retryAttempt + 1, 8);
      final delaySeconds = min(300, 1 << _retryAttempt);
      final retryAt = _clock().add(Duration(seconds: delaySeconds));
      await store.markRetry(
        pending.map((event) => event.id),
        'NETWORK_OR_SERVER',
        retryAt,
      );
      _retryTimer?.cancel();
      if (!_disposed) {
        _retryTimer = Timer(
          Duration(seconds: delaySeconds),
          () => unawaited(_flushPending().catchError(_ignoreAsyncError)),
        );
      }
      logAudioAction('LISTENING_BATCH_RETRY delay=${delaySeconds}s');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _accrue();
      _queueEvent('PLAY_PROGRESS');
    }
  }

  void dispose() {
    if (_disposed) return;
    WidgetsBinding.instance.removeObserver(this);
    _tickTimer?.cancel();
    _retryTimer?.cancel();
    _accrue();
    _queueEvent('PLAY_STOPPED', terminal: true);
    _disposed = true;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
  }

  static String _uuid() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  void _ignoreError(Object error, StackTrace stackTrace) {
    logError('tracking d’écoute isolé', error: error, stackTrace: stackTrace);
  }

  void _ignoreAsyncError(Object error, StackTrace stackTrace) =>
      _ignoreError(error, stackTrace);
}
