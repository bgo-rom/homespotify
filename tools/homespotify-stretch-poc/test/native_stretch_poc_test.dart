import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homespotify_stretch_poc/native_stretch_poc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('le constructeur ne charge ni ne crée de moteur natif', () {
    final channel = _FakeNativeStretchChannel();

    NativeStretchPoc(channel: channel);

    expect(channel.calls, isEmpty);
  });

  test(
    'le cycle explicite initialise, traite, reset et libère une fois',
    () async {
      final channel = _FakeNativeStretchChannel();
      final poc = NativeStretchPoc(channel: channel);

      final info = await poc.initialize(sampleRate: 48000, channels: 2);
      await poc.setTempoRatio(0.8);
      final result = await poc.processPcm(
        Float32List.fromList(<double>[0.1, -0.1, 0.2, -0.2]),
      );
      await poc.reset();
      await poc.dispose();
      await poc.dispose();

      expect(info.engineName, 'HomeSpotify Stretch Engine');
      expect(result.metrics.inputFrames, 2);
      expect(result.output, hasLength(4));
      expect(channel.calls, <String>[
        'create',
        'initialize:48000:2',
        'ratio:0.8',
        'required:2',
        'process:2:10',
        'reset',
        'dispose',
      ]);
    },
  );

  test('les ratios et buffers invalides sont refusés avant le natif', () async {
    final channel = _FakeNativeStretchChannel();
    final poc = NativeStretchPoc(channel: channel);

    await expectLater(
      () => poc.setTempoRatio(1),
      throwsA(
        isA<NativeStretchException>().having(
          (error) => error.code,
          'code',
          NativeStretchErrorCode.notInitialized,
        ),
      ),
    );
    await poc.initialize(sampleRate: 48000, channels: 2);
    await expectLater(() => poc.setTempoRatio(0.69), throwsRangeError);
    await expectLater(() => poc.setTempoRatio(1.31), throwsRangeError);
    await expectLater(
      () => poc.processPcm(Float32List.fromList(<double>[0.1])),
      throwsArgumentError,
    );
    await expectLater(
      () => poc.processPcm(Float32List.fromList(<double>[0.1, -0.1])),
      throwsRangeError,
    );
    await poc.dispose();
  });

  test(
    'un échec d’initialisation libère le handle nouvellement créé',
    () async {
      final channel = _FakeNativeStretchChannel()..failInitialize = true;
      final poc = NativeStretchPoc(channel: channel);

      await expectLater(
        () => poc.initialize(sampleRate: 48000, channels: 2),
        throwsA(isA<NativeStretchException>()),
      );

      expect(channel.calls, <String>[
        'create',
        'initialize:48000:2',
        'dispose',
      ]);
    },
  );

  test(
    'initialisation et dispose concurrents ne fuient aucun handle',
    () async {
      final channel = _FakeNativeStretchChannel();
      final poc = NativeStretchPoc(channel: channel);

      final first = poc.initialize(sampleRate: 48000, channels: 2);
      final second = poc.initialize(sampleRate: 48000, channels: 2);
      final dispose = poc.dispose();

      await Future.wait(<Future<Object?>>[first, second, dispose]);

      expect(channel.calls.where((call) => call == 'create'), hasLength(1));
      expect(
        channel.calls.where((call) => call == 'initialize:48000:2'),
        hasLength(2),
      );
      expect(channel.calls.where((call) => call == 'dispose'), hasLength(1));
      await expectLater(
        () => poc.initialize(sampleRate: 48000, channels: 2),
        throwsA(
          isA<NativeStretchException>().having(
            (error) => error.code,
            'code',
            NativeStretchErrorCode.disposed,
          ),
        ),
      );
    },
  );

  test(
    'le MethodChannel traduit une PlatformException en erreur typée',
    () async {
      const methodChannel = MethodChannel('homespotify/stretch-poc-test');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        throw PlatformException(
          code: 'BUFFER_TOO_SMALL',
          message: 'capacité insuffisante',
          details: <String, Object>{'requiredFrames': 1024},
        );
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(methodChannel, null),
      );
      final channel = MethodChannelNativeStretchChannel(channel: methodChannel);

      await expectLater(
        channel.getRequiredOutputFrames(handle: 1, inputFrames: 512),
        throwsA(
          isA<NativeStretchException>()
              .having(
                (error) => error.code,
                'code',
                NativeStretchErrorCode.bufferTooSmall,
              )
              .having(
                (error) => error.message,
                'message',
                'capacité insuffisante',
              ),
        ),
      );
    },
  );

  test('isAvailable retourne false si le plugin natif est absent', () async {
    const methodChannel = MethodChannel('homespotify/stretch-poc-missing');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      throw MissingPluginException('plugin absent');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(methodChannel, null));

    final channel = MethodChannelNativeStretchChannel(channel: methodChannel);

    expect(await channel.isAvailable(), isFalse);
  });

  test(
    'le MethodChannel sérialise un buffer PCM et valide ses métriques',
    () async {
      const methodChannel = MethodChannel('homespotify/stretch-poc-wire-test');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      late MethodCall received;
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        received = call;
        return <String, Object>{
          'output': Float32List.fromList(<double>[0.1, -0.1]),
          'metrics': <String, Object>{
            'requestedRatio': 0.8,
            'appliedRatio': 0.8,
            'sampleRate': 48000,
            'channels': 2,
            'inputFrames': 1,
            'outputFrames': 1,
            'processingMicros': 50,
            'realtimeFactor': 20.0,
            'latencyFrames': 128,
            'inputPeak': 0.1,
            'outputPeak': 0.1,
            'outOfRangeSamples': 0,
            'profile': 'MUSICAL',
            'engineName': 'HomeSpotify Stretch Engine',
          },
        };
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(methodChannel, null),
      );
      final channel = MethodChannelNativeStretchChannel(channel: methodChannel);
      final input = Float32List.fromList(<double>[0.1, -0.1]);

      final result = await channel.processPcm(
        handle: 9,
        input: input,
        inputFrames: 1,
        outputCapacityFrames: 16,
      );

      expect(received.method, 'processPcm');
      final arguments = received.arguments! as Map<Object?, Object?>;
      expect(arguments['handle'], 9);
      expect(arguments['input'], isA<Float32List>());
      expect(result.output[0], closeTo(0.1, 0.000001));
      expect(result.output[1], closeTo(-0.1, 0.000001));
      expect(result.metrics.profile, HomeSpotifyStretchProfile.musical);
    },
  );
}

final class _FakeNativeStretchChannel implements NativeStretchChannel {
  final List<String> calls = <String>[];
  bool failInitialize = false;
  double ratio = 1;
  int channels = 2;

  @override
  Future<int> create() async {
    calls.add('create');
    return 7;
  }

  @override
  Future<void> dispose({required int handle}) async {
    calls.add('dispose');
  }

  @override
  Future<StretchProcessResult> flush({
    required int handle,
    required int outputCapacityFrames,
  }) async {
    calls.add('flush:$outputCapacityFrames');
    return _result(inputFrames: 0, outputFrames: 0, output: Float32List(0));
  }

  @override
  Future<StretchEngineInfo> getEngineInfo({required int handle}) async =>
      _info();

  @override
  Future<int> getRequiredOutputFrames({
    required int handle,
    required int inputFrames,
  }) async {
    calls.add('required:$inputFrames');
    return inputFrames + 8;
  }

  @override
  Future<StretchEngineInfo> initialize({
    required int handle,
    required int sampleRate,
    required int channels,
  }) async {
    calls.add('initialize:$sampleRate:$channels');
    this.channels = channels;
    if (failInitialize) {
      throw const NativeStretchException(
        code: NativeStretchErrorCode.nativeProcessingFailed,
        message: 'initialisation refusée',
      );
    }
    return _info();
  }

  @override
  Future<bool> isAvailable() async {
    calls.add('available');
    return true;
  }

  @override
  Future<StretchProcessResult> processPcm({
    required int handle,
    required Float32List input,
    required int inputFrames,
    required int outputCapacityFrames,
  }) async {
    calls.add('process:$inputFrames:$outputCapacityFrames');
    return _result(
      inputFrames: inputFrames,
      outputFrames: inputFrames,
      output: input,
    );
  }

  @override
  Future<void> reset({required int handle}) async {
    calls.add('reset');
    ratio = 1;
  }

  @override
  Future<void> setTempoRatio({
    required int handle,
    required double ratio,
  }) async {
    calls.add('ratio:$ratio');
    this.ratio = ratio;
  }

  StretchEngineInfo _info() => StretchEngineInfo(
    engineName: 'HomeSpotify Stretch Engine',
    engineVersion: 'poc',
    initialized: true,
    sampleRate: 48000,
    channels: channels,
    appliedRatio: ratio,
    targetRatio: ratio,
    profile: HomeSpotifyStretchProfile.musical,
    inputLatencyFrames: 64,
    outputLatencyFrames: 64,
  );

  StretchProcessResult _result({
    required int inputFrames,
    required int outputFrames,
    required Float32List output,
  }) => StretchProcessResult(
    output: output,
    metrics: StretchProcessMetrics(
      requestedRatio: ratio,
      appliedRatio: ratio,
      sampleRate: 48000,
      channels: channels,
      inputFrames: inputFrames,
      outputFrames: outputFrames,
      processingMicros: 100,
      realtimeFactor: 10,
      latencyFrames: 128,
      inputPeak: 0.2,
      outputPeak: 0.2,
      outOfRangeSamples: 0,
      profile: HomeSpotifyStretchProfile.musical,
      engineName: 'HomeSpotify Stretch Engine',
    ),
  );
}
