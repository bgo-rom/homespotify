import 'dart:typed_data';

enum NativeStretchErrorCode {
  nativeLibraryUnavailable('NATIVE_LIBRARY_UNAVAILABLE'),
  invalidArgument('INVALID_ARGUMENT'),
  unsupportedFormat('UNSUPPORTED_FORMAT'),
  notInitialized('NOT_INITIALIZED'),
  bufferTooSmall('BUFFER_TOO_SMALL'),
  disposed('DISPOSED'),
  nativeProcessingFailed('NATIVE_PROCESSING_FAILED'),
  protocolError('PROTOCOL_ERROR'),
  unknown('UNKNOWN');

  const NativeStretchErrorCode(this.wireValue);

  final String wireValue;

  static NativeStretchErrorCode fromWire(String value) {
    for (final code in values) {
      if (code.wireValue == value) return code;
    }
    return unknown;
  }
}

final class NativeStretchException implements Exception {
  const NativeStretchException({
    required this.code,
    required this.message,
    this.details,
  });

  final NativeStretchErrorCode code;
  final String message;
  final Object? details;

  @override
  String toString() => '${code.wireValue}: $message';
}

enum HomeSpotifyStretchProfile {
  transparent('TRANSPARENT'),
  musical('MUSICAL'),
  extremeHq('EXTREME_HQ'),
  unknown('UNKNOWN');

  const HomeSpotifyStretchProfile(this.wireValue);

  final String wireValue;

  static HomeSpotifyStretchProfile fromWire(Object? value) {
    for (final profile in values) {
      if (profile.wireValue == value) return profile;
    }
    return unknown;
  }
}

final class StretchEngineInfo {
  const StretchEngineInfo({
    required this.engineName,
    required this.initialized,
    required this.appliedRatio,
    required this.targetRatio,
    required this.profile,
    required this.inputLatencyFrames,
    required this.outputLatencyFrames,
    this.engineVersion,
    this.foundation,
    this.foundationVersion,
    this.sampleRate,
    this.channels,
    this.pendingProfile,
    this.pitchRatio = 1,
    this.qualityMode,
    this.blockSamples,
    this.intervalSamples,
    this.profileChangePending = false,
    this.lastError,
  });

  final String engineName;
  final String? engineVersion;
  final String? foundation;
  final String? foundationVersion;
  final bool initialized;
  final int? sampleRate;
  final int? channels;
  final double appliedRatio;
  final double targetRatio;
  final HomeSpotifyStretchProfile profile;
  final HomeSpotifyStretchProfile? pendingProfile;
  final double pitchRatio;
  final String? qualityMode;
  final int? blockSamples;
  final int? intervalSamples;
  final bool profileChangePending;
  final int inputLatencyFrames;
  final int outputLatencyFrames;
  final String? lastError;

  int get latencyFrames => inputLatencyFrames + outputLatencyFrames;

  double? get latencyMs => sampleRate == null || sampleRate! <= 0
      ? null
      : latencyFrames * 1000 / sampleRate!;

  factory StretchEngineInfo.fromWire(Map<Object?, Object?> value) {
    final engineName = value['engineName'];
    if (engineName is! String || engineName.isEmpty) {
      throw const NativeStretchException(
        code: NativeStretchErrorCode.protocolError,
        message: 'engineName absent de la réponse native.',
      );
    }

    return StretchEngineInfo(
      engineName: engineName,
      engineVersion: _optionalString(value['engineVersion']),
      foundation: _optionalString(value['foundation']),
      foundationVersion: _optionalString(value['foundationVersion']),
      initialized: _bool(value['initialized'], fallback: false),
      sampleRate: _optionalInt(value['sampleRate']),
      channels: _optionalInt(value['channels']),
      appliedRatio: _double(value['appliedRatio'], fallback: 1),
      targetRatio: _double(value['targetRatio'], fallback: 1),
      profile: HomeSpotifyStretchProfile.fromWire(value['profile']),
      pendingProfile: value['pendingProfile'] == null
          ? null
          : HomeSpotifyStretchProfile.fromWire(value['pendingProfile']),
      pitchRatio: _double(value['pitchRatio'], fallback: 1),
      qualityMode: _optionalString(value['qualityMode']),
      blockSamples: _optionalInt(value['blockSamples']),
      intervalSamples: _optionalInt(value['intervalSamples']),
      profileChangePending: _bool(
        value['profileChangePending'],
        fallback: false,
      ),
      inputLatencyFrames: _int(value['inputLatencyFrames'], fallback: 0),
      outputLatencyFrames: _int(value['outputLatencyFrames'], fallback: 0),
      lastError: _optionalString(value['lastError']),
    );
  }
}

final class StretchProcessMetrics {
  const StretchProcessMetrics({
    required this.requestedRatio,
    required this.appliedRatio,
    required this.sampleRate,
    required this.channels,
    required this.inputFrames,
    required this.outputFrames,
    required this.processingMicros,
    required this.realtimeFactor,
    required this.latencyFrames,
    required this.inputPeak,
    required this.outputPeak,
    required this.outOfRangeSamples,
    this.inputOutOfRangeSamples = 0,
    int? outputOutOfRangeSamples,
    required this.profile,
    required this.engineName,
  }) : outputOutOfRangeSamples = outputOutOfRangeSamples ?? outOfRangeSamples;

  final double requestedRatio;
  final double appliedRatio;
  final int sampleRate;
  final int channels;
  final int inputFrames;
  final int outputFrames;
  final int processingMicros;

  /// Durée audio source divisée par la durée de calcul native.
  final double realtimeFactor;
  final int latencyFrames;
  final double inputPeak;
  final double outputPeak;
  final int outOfRangeSamples;
  final int inputOutOfRangeSamples;
  final int outputOutOfRangeSamples;
  final HomeSpotifyStretchProfile profile;
  final String engineName;

  factory StretchProcessMetrics.fromWire(Map<Object?, Object?> value) {
    final engineName = value['engineName'];
    if (engineName is! String || engineName.isEmpty) {
      throw const NativeStretchException(
        code: NativeStretchErrorCode.protocolError,
        message: 'engineName absent des métriques natives.',
      );
    }

    return StretchProcessMetrics(
      requestedRatio: _requiredDouble(value, 'requestedRatio'),
      appliedRatio: _requiredDouble(value, 'appliedRatio'),
      sampleRate: _requiredInt(value, 'sampleRate'),
      channels: _requiredInt(value, 'channels'),
      inputFrames: _requiredInt(value, 'inputFrames'),
      outputFrames: _requiredInt(value, 'outputFrames'),
      processingMicros: _requiredInt(value, 'processingMicros'),
      realtimeFactor: _requiredDouble(value, 'realtimeFactor'),
      latencyFrames: _requiredInt(value, 'latencyFrames'),
      inputPeak: _requiredDouble(value, 'inputPeak'),
      outputPeak: _requiredDouble(value, 'outputPeak'),
      outOfRangeSamples: _requiredInt(value, 'outOfRangeSamples'),
      inputOutOfRangeSamples: _int(value['inputOverRangeSamples'], fallback: 0),
      outputOutOfRangeSamples: _int(
        value['outputOverRangeSamples'],
        fallback: _requiredInt(value, 'outOfRangeSamples'),
      ),
      profile: HomeSpotifyStretchProfile.fromWire(value['profile']),
      engineName: engineName,
    );
  }
}

final class StretchProcessResult {
  StretchProcessResult({required Float32List output, required this.metrics})
    : output = Float32List.fromList(output);

  final Float32List output;
  final StretchProcessMetrics metrics;
}

final class PcmFixture {
  PcmFixture({
    required this.label,
    required this.sampleRate,
    required this.channels,
    required Float32List samples,
  }) : samples = Float32List.fromList(samples) {
    if (label.trim().isEmpty) {
      throw ArgumentError.value(label, 'label', 'Le libellé est vide.');
    }
    if (sampleRate <= 0) {
      throw RangeError.range(sampleRate, 1, null, 'sampleRate');
    }
    if (channels != 1 && channels != 2) {
      throw ArgumentError.value(channels, 'channels', 'Mono ou stéréo requis.');
    }
    if (samples.isEmpty || samples.length % channels != 0) {
      throw ArgumentError.value(
        samples.length,
        'samples',
        'Le buffer doit contenir des frames interleaved complètes.',
      );
    }
  }

  final String label;
  final int sampleRate;
  final int channels;
  final Float32List samples;

  int get frames => samples.length ~/ channels;
}

int _requiredInt(Map<Object?, Object?> value, String key) {
  final raw = value[key];
  if (raw is num && raw.isFinite) return raw.toInt();
  throw NativeStretchException(
    code: NativeStretchErrorCode.protocolError,
    message: '$key absent ou invalide dans la réponse native.',
  );
}

double _requiredDouble(Map<Object?, Object?> value, String key) {
  final raw = value[key];
  if (raw is num && raw.isFinite) return raw.toDouble();
  throw NativeStretchException(
    code: NativeStretchErrorCode.protocolError,
    message: '$key absent ou invalide dans la réponse native.',
  );
}

int _int(Object? value, {required int fallback}) =>
    value is num && value.isFinite ? value.toInt() : fallback;

int? _optionalInt(Object? value) =>
    value is num && value.isFinite ? value.toInt() : null;

double _double(Object? value, {required double fallback}) =>
    value is num && value.isFinite ? value.toDouble() : fallback;

bool _bool(Object? value, {required bool fallback}) =>
    value is bool ? value : fallback;

String? _optionalString(Object? value) => value is String ? value : null;
