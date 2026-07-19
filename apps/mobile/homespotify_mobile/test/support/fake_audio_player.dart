import 'dart:async';

import 'package:just_audio/just_audio.dart';

/// Fake minimal de just_audio : seuls les membres réellement utilisés par le
/// contrôleur d'extraits sont implémentés ; tout le reste échoue franchement.
class FakeAudioPlayer implements AudioPlayer {
  final StreamController<PlayerState> _states =
      StreamController<PlayerState>.broadcast();
  final StreamController<Duration> _positions =
      StreamController<Duration>.broadcast();
  final StreamController<Duration?> _durations =
      StreamController<Duration?>.broadcast();
  bool _playing = false;
  final List<String> loadedUrls = [];
  int stopCalls = 0;
  bool disposed = false;

  @override
  Stream<PlayerState> get playerStateStream => _states.stream;

  @override
  Stream<Duration> get positionStream => _positions.stream;

  @override
  Stream<Duration?> get durationStream => _durations.stream;

  @override
  bool get playing => _playing;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #setUrl:
        loadedUrls.add(invocation.positionalArguments.first as String);
        return Future<Duration?>.value();
      case #play:
        _playing = true;
        _states.add(PlayerState(true, ProcessingState.ready));
        return Future<void>.value();
      case #pause:
        _playing = false;
        _states.add(PlayerState(false, ProcessingState.ready));
        return Future<void>.value();
      case #stop:
        stopCalls += 1;
        _playing = false;
        _states.add(PlayerState(false, ProcessingState.idle));
        return Future<void>.value();
      case #dispose:
        disposed = true;
        _positions.close();
        _durations.close();
        return _states.close();
      default:
        throw UnimplementedError('FakeAudioPlayer: ${invocation.memberName}');
    }
  }
}
