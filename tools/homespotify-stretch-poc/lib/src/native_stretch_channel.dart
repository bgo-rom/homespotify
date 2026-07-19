import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'native_stretch_models.dart';

abstract interface class NativeStretchChannel {
  Future<bool> isAvailable();

  Future<int> create();

  Future<StretchEngineInfo> initialize({
    required int handle,
    required int sampleRate,
    required int channels,
  });

  Future<void> setTempoRatio({required int handle, required double ratio});

  Future<int> getRequiredOutputFrames({
    required int handle,
    required int inputFrames,
  });

  Future<StretchProcessResult> processPcm({
    required int handle,
    required Float32List input,
    required int inputFrames,
    required int outputCapacityFrames,
  });

  Future<StretchProcessResult> flush({
    required int handle,
    required int outputCapacityFrames,
  });

  Future<void> reset({required int handle});

  Future<StretchEngineInfo> getEngineInfo({required int handle});

  Future<void> dispose({required int handle});
}

final class MethodChannelNativeStretchChannel implements NativeStretchChannel {
  MethodChannelNativeStretchChannel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'com.homespotify/stretch_poc';

  final MethodChannel _channel;

  @override
  Future<bool> isAvailable() async {
    final Object? value;
    try {
      value = await _invoke<Object?>('isAvailable');
    } on NativeStretchException catch (error) {
      if (error.code == NativeStretchErrorCode.nativeLibraryUnavailable) {
        return false;
      }
      rethrow;
    }
    if (value is bool) return value;
    if (value is Map && value['available'] is bool) {
      return value['available'] as bool;
    }
    throw _protocolError('Réponse isAvailable invalide.');
  }

  @override
  Future<int> create() async {
    final value = await _invoke<Object?>('create');
    if (value is num && value.isFinite && value.toInt() > 0) {
      return value.toInt();
    }
    throw _protocolError('Handle natif invalide.');
  }

  @override
  Future<StretchEngineInfo> initialize({
    required int handle,
    required int sampleRate,
    required int channels,
  }) async {
    final value = await _invoke<Object?>('initialize', <String, Object>{
      'handle': handle,
      'sampleRate': sampleRate,
      'channels': channels,
    });
    return StretchEngineInfo.fromWire(_wireMap(value, 'initialize'));
  }

  @override
  Future<void> setTempoRatio({required int handle, required double ratio}) =>
      _invoke<void>('setTempoRatio', <String, Object>{
        'handle': handle,
        'ratio': ratio,
      });

  @override
  Future<int> getRequiredOutputFrames({
    required int handle,
    required int inputFrames,
  }) async {
    final value = await _invoke<Object?>(
      'getRequiredOutputFrames',
      <String, Object>{'handle': handle, 'inputFrames': inputFrames},
    );
    if (value is num && value.isFinite && value.toInt() >= 0) {
      return value.toInt();
    }
    throw _protocolError('Capacité de sortie native invalide.');
  }

  @override
  Future<StretchProcessResult> processPcm({
    required int handle,
    required Float32List input,
    required int inputFrames,
    required int outputCapacityFrames,
  }) async {
    final value = await _invoke<Object?>('processPcm', <String, Object>{
      'handle': handle,
      'input': input,
      'inputFrames': inputFrames,
      'outputCapacityFrames': outputCapacityFrames,
    });
    return _processResult(value, 'processPcm');
  }

  @override
  Future<StretchProcessResult> flush({
    required int handle,
    required int outputCapacityFrames,
  }) async {
    final value = await _invoke<Object?>('flush', <String, Object>{
      'handle': handle,
      'outputCapacityFrames': outputCapacityFrames,
    });
    return _processResult(value, 'flush');
  }

  @override
  Future<void> reset({required int handle}) =>
      _invoke<void>('reset', <String, Object>{'handle': handle});

  @override
  Future<StretchEngineInfo> getEngineInfo({required int handle}) async {
    final value = await _invoke<Object?>('getEngineInfo', <String, Object>{
      'handle': handle,
    });
    return StretchEngineInfo.fromWire(_wireMap(value, 'getEngineInfo'));
  }

  @override
  Future<void> dispose({required int handle}) =>
      _invoke<void>('dispose', <String, Object>{'handle': handle});

  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException catch (error) {
      throw NativeStretchException(
        code: NativeStretchErrorCode.nativeLibraryUnavailable,
        message: 'Le module natif HomeSpotify Stretch est indisponible.',
        details: error.message,
      );
    } on PlatformException catch (error) {
      throw NativeStretchException(
        code: NativeStretchErrorCode.fromWire(error.code),
        message: error.message ?? 'Erreur native sans message.',
        details: error.details,
      );
    }
  }

  StretchProcessResult _processResult(Object? value, String method) {
    final map = _wireMap(value, method);
    final output = map['output'];
    if (output is! Float32List) {
      throw _protocolError('Buffer de sortie $method invalide.');
    }
    final metricsValue = map['metrics'];
    final metrics = StretchProcessMetrics.fromWire(
      _wireMap(metricsValue, '$method.metrics'),
    );
    final expectedSamples = metrics.outputFrames * metrics.channels;
    if (expectedSamples != output.length) {
      throw _protocolError(
        '$method annonce $expectedSamples échantillons, '
        'mais en retourne ${output.length}.',
      );
    }
    return StretchProcessResult(output: output, metrics: metrics);
  }

  Map<Object?, Object?> _wireMap(Object? value, String method) {
    if (value is Map) return Map<Object?, Object?>.from(value);
    throw _protocolError('Réponse $method invalide.');
  }

  NativeStretchException _protocolError(String message) =>
      NativeStretchException(
        code: NativeStretchErrorCode.protocolError,
        message: message,
      );
}
