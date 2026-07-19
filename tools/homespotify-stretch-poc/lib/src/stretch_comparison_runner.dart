import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'native_stretch_client.dart';
import 'native_stretch_models.dart';

typedef StretchPocSessionFactory = StretchPocSession Function();

final class StretchComparisonArtifact {
  const StretchComparisonArtifact({
    required this.path,
    required this.ratio,
    this.metrics,
  });

  final String path;
  final double ratio;
  final StretchProcessMetrics? metrics;
}

final class StretchComparisonReport {
  const StretchComparisonReport({
    required this.outputDirectory,
    required this.fixture,
    required this.engineInfo,
    required this.artifacts,
  });

  final String outputDirectory;
  final PcmFixture fixture;
  final StretchEngineInfo engineInfo;
  final List<StretchComparisonArtifact> artifacts;
}

final class StretchComparisonRunner {
  StretchComparisonRunner({required StretchPocSessionFactory sessionFactory})
    : _sessionFactory = sessionFactory;

  static const defaultRatios = <double>[0.70, 0.80, 1.20, 1.30];

  final StretchPocSessionFactory _sessionFactory;

  Future<StretchComparisonReport> run({
    required Directory outputRoot,
    PcmFixture? fixture,
    List<double> ratios = defaultRatios,
  }) async {
    _validateArtifactRoot(outputRoot);
    if (ratios.isEmpty) {
      throw ArgumentError.value(
        ratios,
        'ratios',
        'Au moins un ratio est requis.',
      );
    }
    for (final ratio in ratios) {
      _validateRatio(ratio);
    }

    final source = fixture ?? createSyntheticMusicFixture();
    await outputRoot.create(recursive: true);
    final outputDirectory = await outputRoot.createTemp('homespotify-stretch-');
    final artifacts = <StretchComparisonArtifact>[];
    final session = _sessionFactory();
    try {
      if (!await session.isAvailable()) {
        throw const NativeStretchException(
          code: NativeStretchErrorCode.nativeLibraryUnavailable,
          message: 'Le module natif HomeSpotify Stretch est indisponible.',
        );
      }
      var engineInfo = await session.initialize(
        sampleRate: source.sampleRate,
        channels: source.channels,
      );
      final original = File(
        '${outputDirectory.path}${Platform.pathSeparator}original.wav',
      );
      await _writeFloat32Wav(original, source);
      artifacts.add(StretchComparisonArtifact(path: original.path, ratio: 1));

      for (final ratio in ratios) {
        await session.reset();
        await session.setTempoRatio(ratio);
        final processed = await session.processPcm(source.samples);
        final tail = await session.flush();
        final combined = _combine(processed.output, tail.output);
        final metrics = _aggregateMetrics(
          source: source,
          ratio: ratio,
          output: combined,
          processed: processed.metrics,
          flushed: tail.metrics,
        );
        final file = File(
          '${outputDirectory.path}${Platform.pathSeparator}'
          'signalsmith_${_ratioFilePart(ratio)}x.wav',
        );
        await _writeFloat32Wav(
          file,
          PcmFixture(
            label: 'Signalsmith ${ratio.toStringAsFixed(2)}x',
            sampleRate: source.sampleRate,
            channels: source.channels,
            samples: combined,
          ),
        );
        artifacts.add(
          StretchComparisonArtifact(
            path: file.path,
            ratio: ratio,
            metrics: metrics,
          ),
        );
        engineInfo = await session.getEngineInfo();
      }

      return StretchComparisonReport(
        outputDirectory: outputDirectory.path,
        fixture: source,
        engineInfo: engineInfo,
        artifacts: List<StretchComparisonArtifact>.unmodifiable(artifacts),
      );
    } catch (_) {
      if (await outputDirectory.exists()) {
        await outputDirectory.delete(recursive: true);
      }
      rethrow;
    } finally {
      await session.dispose();
    }
  }
}

void _validateArtifactRoot(Directory outputRoot) {
  final segments = outputRoot.absolute.path.toLowerCase().split(
    RegExp(r'[\\/]+'),
  );
  final isTestLocation = segments.any(
    (segment) =>
        segment == 'artifacts' ||
        segment == 'temp' ||
        segment == 'tmp' ||
        segment.contains('test'),
  );
  if (!isTestLocation) {
    throw ArgumentError.value(
      outputRoot.path,
      'outputRoot',
      'Le POC écrit uniquement dans un dossier temporaire ou de test.',
    );
  }
}

PcmFixture createSyntheticMusicFixture({
  int sampleRate = 48000,
  int channels = 2,
  Duration duration = const Duration(seconds: 1),
}) {
  if (sampleRate <= 0) {
    throw RangeError.range(sampleRate, 1, null, 'sampleRate');
  }
  if (channels != 1 && channels != 2) {
    throw ArgumentError.value(channels, 'channels', 'Mono ou stéréo requis.');
  }
  final frames = (sampleRate * duration.inMicroseconds / 1000000).round();
  if (frames <= 0 || frames * channels > NativeStretchPoc.maxInputSamples) {
    throw RangeError.range(
      frames * channels,
      1,
      NativeStretchPoc.maxInputSamples,
      'duration',
    );
  }

  final samples = Float32List(frames * channels);
  for (var frame = 0; frame < frames; frame += 1) {
    final time = frame / sampleRate;
    final transientPhase = frame % (sampleRate ~/ 4);
    final transient = transientPhase < 240
        ? 0.18 * math.exp(-transientPhase / 55)
        : 0.0;
    final left =
        0.30 * math.sin(2 * math.pi * 110 * time) +
        0.17 * math.sin(2 * math.pi * 440 * time) +
        transient;
    final right =
        0.28 * math.sin(2 * math.pi * 110 * time + 0.025) +
        0.16 * math.sin(2 * math.pi * 660 * time) +
        transient * 0.92;
    samples[frame * channels] = left;
    if (channels == 2) samples[frame * channels + 1] = right;
  }
  return PcmFixture(
    label: 'Fixture PCM synthétique HomeSpotify',
    sampleRate: sampleRate,
    channels: channels,
    samples: samples,
  );
}

StretchProcessMetrics _aggregateMetrics({
  required PcmFixture source,
  required double ratio,
  required Float32List output,
  required StretchProcessMetrics processed,
  required StretchProcessMetrics flushed,
}) {
  final processingMicros =
      processed.processingMicros + flushed.processingMicros;
  final sourceMicros = source.frames * 1000000 / source.sampleRate;
  return StretchProcessMetrics(
    requestedRatio: ratio,
    appliedRatio: processed.appliedRatio,
    sampleRate: source.sampleRate,
    channels: source.channels,
    inputFrames: source.frames,
    outputFrames: output.length ~/ source.channels,
    processingMicros: processingMicros,
    realtimeFactor: processingMicros == 0 ? 0 : sourceMicros / processingMicros,
    latencyFrames: processed.latencyFrames,
    inputPeak: _peak(source.samples),
    outputPeak: _peak(output),
    outOfRangeSamples: _outOfRangeSamples(output),
    inputOutOfRangeSamples: _outOfRangeSamples(source.samples),
    outputOutOfRangeSamples: _outOfRangeSamples(output),
    profile: processed.profile,
    engineName: processed.engineName,
  );
}

Float32List _combine(Float32List first, Float32List second) {
  final output = Float32List(first.length + second.length);
  output.setRange(0, first.length, first);
  output.setRange(first.length, output.length, second);
  return output;
}

double _peak(Float32List samples) {
  var peak = 0.0;
  for (final sample in samples) {
    final absolute = sample.abs();
    if (absolute > peak) peak = absolute;
  }
  return peak;
}

int _outOfRangeSamples(Float32List samples) {
  var count = 0;
  for (final sample in samples) {
    if (!sample.isFinite || sample < -1 || sample > 1) count += 1;
  }
  return count;
}

String _ratioFilePart(double ratio) =>
    ratio.toStringAsFixed(2).replaceFirst('.', '_');

void _validateRatio(double ratio) {
  if (!ratio.isFinite ||
      ratio < NativeStretchPoc.minTempoRatio ||
      ratio > NativeStretchPoc.maxTempoRatio) {
    throw RangeError.value(
      ratio,
      'ratio',
      'Le ratio doit être compris entre '
          '${NativeStretchPoc.minTempoRatio} et '
          '${NativeStretchPoc.maxTempoRatio}.',
    );
  }
}

Future<void> _writeFloat32Wav(File file, PcmFixture fixture) async {
  final dataBytes = fixture.samples.length * Float32List.bytesPerElement;
  final bytes = ByteData(44 + dataBytes);
  _writeAscii(bytes, 0, 'RIFF');
  bytes.setUint32(4, 36 + dataBytes, Endian.little);
  _writeAscii(bytes, 8, 'WAVE');
  _writeAscii(bytes, 12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 3, Endian.little); // IEEE float32, sans conversion.
  bytes.setUint16(22, fixture.channels, Endian.little);
  bytes.setUint32(24, fixture.sampleRate, Endian.little);
  final blockAlign = fixture.channels * Float32List.bytesPerElement;
  bytes.setUint32(28, fixture.sampleRate * blockAlign, Endian.little);
  bytes.setUint16(32, blockAlign, Endian.little);
  bytes.setUint16(34, 32, Endian.little);
  _writeAscii(bytes, 36, 'data');
  bytes.setUint32(40, dataBytes, Endian.little);
  var offset = 44;
  for (final sample in fixture.samples) {
    bytes.setFloat32(offset, sample, Endian.little);
    offset += Float32List.bytesPerElement;
  }
  await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
}

void _writeAscii(ByteData bytes, int offset, String value) {
  for (var index = 0; index < value.length; index += 1) {
    bytes.setUint8(offset + index, value.codeUnitAt(index));
  }
}
