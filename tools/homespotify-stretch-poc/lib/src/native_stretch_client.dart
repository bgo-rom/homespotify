import 'dart:async';
import 'dart:typed_data';

import 'native_stretch_channel.dart';
import 'native_stretch_models.dart';

abstract interface class StretchPocSession {
  Future<bool> isAvailable();

  Future<StretchEngineInfo> initialize({
    required int sampleRate,
    required int channels,
  });

  Future<void> setTempoRatio(double ratio);

  Future<StretchProcessResult> processPcm(
    Float32List input, {
    int? outputCapacityFrames,
  });

  Future<StretchProcessResult> flush({int? outputCapacityFrames});

  Future<void> reset();

  Future<StretchEngineInfo> getEngineInfo();

  Future<void> dispose();
}

final class NativeStretchPoc implements StretchPocSession {
  NativeStretchPoc({NativeStretchChannel? channel})
    : _channel = channel ?? MethodChannelNativeStretchChannel();

  static const minTempoRatio = 0.70;
  static const maxTempoRatio = 1.30;

  /// Limites volontaires du POC MethodChannel, impropre au streaming temps réel.
  static const maxInputFrames = 480000;
  static const maxInputSamples = maxInputFrames * 2;
  static const maxOutputSamples = 1536 * 1024;

  final NativeStretchChannel _channel;
  int? _handle;
  int? _channels;
  bool _disposed = false;
  Future<void> _lifecycleOperations = Future<void>.value();

  @override
  Future<bool> isAvailable() {
    _ensureOpen();
    return _channel.isAvailable();
  }

  @override
  Future<StretchEngineInfo> initialize({
    required int sampleRate,
    required int channels,
  }) => _serializeLifecycle(() async {
    _ensureOpen();
    if (sampleRate <= 0) {
      throw RangeError.range(sampleRate, 1, null, 'sampleRate');
    }
    if (channels != 1 && channels != 2) {
      throw ArgumentError.value(channels, 'channels', 'Mono ou stéréo requis.');
    }

    final existingHandle = _handle;
    final handle = existingHandle ?? await _channel.create();
    try {
      final info = await _channel.initialize(
        handle: handle,
        sampleRate: sampleRate,
        channels: channels,
      );
      _handle = handle;
      _channels = channels;
      return info;
    } catch (error, stackTrace) {
      if (existingHandle == null) {
        try {
          await _channel.dispose(handle: handle);
        } catch (cleanupError) {
          Error.throwWithStackTrace(
            NativeStretchException(
              code: NativeStretchErrorCode.nativeProcessingFailed,
              message:
                  'L’initialisation et la libération du handle natif ont échoué.',
              details: <String, Object>{
                'initializationError': error.toString(),
                'cleanupError': cleanupError.toString(),
              },
            ),
            stackTrace,
          );
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  });

  @override
  Future<void> setTempoRatio(double ratio) {
    _validateRatio(ratio);
    return _channel.setTempoRatio(handle: _initializedHandle, ratio: ratio);
  }

  @override
  Future<StretchProcessResult> processPcm(
    Float32List input, {
    int? outputCapacityFrames,
  }) async {
    final handle = _initializedHandle;
    final channels = _channels!;
    if (input.isEmpty || input.length % channels != 0) {
      throw ArgumentError.value(
        input.length,
        'input',
        'Le buffer doit contenir des frames interleaved complètes.',
      );
    }
    if (input.length > maxInputSamples) {
      throw RangeError.range(input.length, 1, maxInputSamples, 'input.length');
    }

    final inputFrames = input.length ~/ channels;
    if (inputFrames < 2) {
      throw RangeError.range(inputFrames, 2, maxInputFrames, 'inputFrames');
    }
    if (inputFrames > maxInputFrames) {
      throw RangeError.range(inputFrames, 1, maxInputFrames, 'inputFrames');
    }
    final capacity =
        outputCapacityFrames ??
        await _channel.getRequiredOutputFrames(
          handle: handle,
          inputFrames: inputFrames,
        );
    _validateOutputCapacity(capacity, channels);
    return _channel.processPcm(
      handle: handle,
      input: input,
      inputFrames: inputFrames,
      outputCapacityFrames: capacity,
    );
  }

  @override
  Future<StretchProcessResult> flush({int? outputCapacityFrames}) async {
    final handle = _initializedHandle;
    final channels = _channels!;
    final required =
        outputCapacityFrames ??
        await _channel.getRequiredOutputFrames(handle: handle, inputFrames: 0);
    final capacity = required == 0 ? 1 : required;
    _validateOutputCapacity(capacity, channels);
    return _channel.flush(handle: handle, outputCapacityFrames: capacity);
  }

  @override
  Future<void> reset() => _channel.reset(handle: _initializedHandle);

  @override
  Future<StretchEngineInfo> getEngineInfo() =>
      _channel.getEngineInfo(handle: _initializedHandle);

  @override
  Future<void> dispose() => _serializeLifecycle(() async {
    if (_disposed) return;
    _disposed = true;
    final handle = _handle;
    _handle = null;
    _channels = null;
    if (handle != null) await _channel.dispose(handle: handle);
  });

  Future<T> _serializeLifecycle<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _lifecycleOperations = _lifecycleOperations.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  int get _initializedHandle {
    _ensureOpen();
    final handle = _handle;
    if (handle == null || _channels == null) {
      throw const NativeStretchException(
        code: NativeStretchErrorCode.notInitialized,
        message: 'Le moteur doit être initialisé avant cette opération.',
      );
    }
    return handle;
  }

  void _ensureOpen() {
    if (_disposed) {
      throw const NativeStretchException(
        code: NativeStretchErrorCode.disposed,
        message: 'Cette session HomeSpotify Stretch est libérée.',
      );
    }
  }

  void _validateRatio(double ratio) {
    _ensureOpen();
    if (!ratio.isFinite || ratio < minTempoRatio || ratio > maxTempoRatio) {
      throw RangeError.value(
        ratio,
        'ratio',
        'Le ratio doit être compris entre $minTempoRatio et $maxTempoRatio.',
      );
    }
  }

  void _validateOutputCapacity(int capacityFrames, int channels) {
    if (capacityFrames <= 0) {
      throw RangeError.range(capacityFrames, 1, null, 'outputCapacityFrames');
    }
    final samples = capacityFrames * channels;
    if (samples > maxOutputSamples) {
      throw RangeError.range(
        samples,
        1,
        maxOutputSamples,
        'outputCapacitySamples',
      );
    }
  }
}
