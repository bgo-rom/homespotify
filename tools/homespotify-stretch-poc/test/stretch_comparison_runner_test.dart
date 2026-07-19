import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:homespotify_stretch_poc/native_stretch_poc.dart';

void main() {
  test(
    'le runner écrit cinq WAV float32 bornés dans un dossier unique',
    () async {
      final root = await Directory.systemTemp.createTemp('stretch-poc-test-');
      addTearDown(() => root.delete(recursive: true));
      late _FakeStretchSession session;
      final runner = StretchComparisonRunner(
        sessionFactory: () => session = _FakeStretchSession(),
      );
      final fixture = createSyntheticMusicFixture(
        sampleRate: 8000,
        duration: const Duration(milliseconds: 20),
      );
      final sourceBefore = Float32List.fromList(fixture.samples);

      final report = await runner.run(outputRoot: root, fixture: fixture);

      expect(report.artifacts, hasLength(5));
      expect(fixture.samples, sourceBefore);
      expect(report.outputDirectory, startsWith(root.path));
      expect(session.ratios, <double>[0.70, 0.80, 1.20, 1.30]);
      expect(session.disposeCalls, 1);
      expect(
        report.artifacts.map((artifact) => File(artifact.path).existsSync()),
        everyElement(isTrue),
      );
      expect(
        report.artifacts.map(
          (artifact) => artifact.path.split(Platform.pathSeparator).last,
        ),
        <String>[
          'original.wav',
          'signalsmith_0_70x.wav',
          'signalsmith_0_80x.wav',
          'signalsmith_1_20x.wav',
          'signalsmith_1_30x.wav',
        ],
      );

      final original = await File(report.artifacts.first.path).readAsBytes();
      expect(String.fromCharCodes(original.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(original.sublist(8, 12)), 'WAVE');
      final header = ByteData.sublistView(Uint8List.fromList(original));
      expect(header.getUint16(20, Endian.little), 3);
      expect(header.getUint16(34, Endian.little), 32);
      expect(
        report.artifacts
            .skip(1)
            .map((artifact) => artifact.metrics?.outOfRangeSamples),
        everyElement(0),
      );
    },
  );

  test(
    'un ratio hors contrat est rejeté avant toute création de session',
    () async {
      final root = await Directory.systemTemp.createTemp('stretch-poc-test-');
      addTearDown(() => root.delete(recursive: true));
      var factoryCalls = 0;
      final runner = StretchComparisonRunner(
        sessionFactory: () {
          factoryCalls += 1;
          return _FakeStretchSession();
        },
      );

      await expectLater(
        () => runner.run(outputRoot: root, ratios: const <double>[0.69]),
        throwsRangeError,
      );
      expect(factoryCalls, 0);
    },
  );

  test('un dossier qui n’est ni temporaire ni de test est refusé', () async {
    var factoryCalls = 0;
    final runner = StretchComparisonRunner(
      sessionFactory: () {
        factoryCalls += 1;
        return _FakeStretchSession();
      },
    );

    await expectLater(
      () => runner.run(outputRoot: Directory('C:/music/library')),
      throwsArgumentError,
    );
    expect(factoryCalls, 0);
  });
}

final class _FakeStretchSession implements StretchPocSession {
  final List<double> ratios = <double>[];
  int disposeCalls = 0;
  int sampleRate = 48000;
  int channels = 2;
  double ratio = 1;

  @override
  Future<void> dispose() async {
    disposeCalls += 1;
  }

  @override
  Future<StretchProcessResult> flush({int? outputCapacityFrames}) async =>
      _result(Float32List(0), inputFrames: 0, processingMicros: 5);

  @override
  Future<StretchEngineInfo> getEngineInfo() async => _info();

  @override
  Future<StretchEngineInfo> initialize({
    required int sampleRate,
    required int channels,
  }) async {
    this.sampleRate = sampleRate;
    this.channels = channels;
    return _info();
  }

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<StretchProcessResult> processPcm(
    Float32List input, {
    int? outputCapacityFrames,
  }) async {
    final inputFrames = input.length ~/ channels;
    final outputFrames = (inputFrames / ratio).round();
    final output = Float32List(outputFrames * channels);
    for (var frame = 0; frame < outputFrames; frame += 1) {
      final sourceFrame = (frame * ratio).floor().clamp(0, inputFrames - 1);
      for (var channel = 0; channel < channels; channel += 1) {
        output[frame * channels + channel] =
            input[sourceFrame * channels + channel];
      }
    }
    return _result(output, inputFrames: inputFrames, processingMicros: 50);
  }

  @override
  Future<void> reset() async {
    ratio = 1;
  }

  @override
  Future<void> setTempoRatio(double ratio) async {
    this.ratio = ratio;
    ratios.add(ratio);
  }

  StretchEngineInfo _info() => StretchEngineInfo(
    engineName: 'HomeSpotify Stretch Engine fake',
    initialized: true,
    sampleRate: sampleRate,
    channels: channels,
    appliedRatio: ratio,
    targetRatio: ratio,
    profile: _profile(ratio),
    inputLatencyFrames: 32,
    outputLatencyFrames: 32,
  );

  StretchProcessResult _result(
    Float32List output, {
    required int inputFrames,
    required int processingMicros,
  }) => StretchProcessResult(
    output: output,
    metrics: StretchProcessMetrics(
      requestedRatio: ratio,
      appliedRatio: ratio,
      sampleRate: sampleRate,
      channels: channels,
      inputFrames: inputFrames,
      outputFrames: output.length ~/ channels,
      processingMicros: processingMicros,
      realtimeFactor: 10,
      latencyFrames: 64,
      inputPeak: 0.65,
      outputPeak: 0.65,
      outOfRangeSamples: 0,
      profile: _profile(ratio),
      engineName: 'HomeSpotify Stretch Engine fake',
    ),
  );

  HomeSpotifyStretchProfile _profile(double ratio) {
    if (ratio >= 0.95 && ratio <= 1.05) {
      return HomeSpotifyStretchProfile.transparent;
    }
    if (ratio < 0.80 || ratio > 1.20) {
      return HomeSpotifyStretchProfile.extremeHq;
    }
    return HomeSpotifyStretchProfile.musical;
  }
}
