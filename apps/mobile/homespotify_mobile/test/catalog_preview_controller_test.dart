import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homespotify_mobile/src/features/catalog_search/domain/catalog_models.dart';
import 'package:homespotify_mobile/src/features/catalog_search/presentation/catalog_preview_controller.dart';
import 'package:homespotify_mobile/src/features/player/audio/homespotify_audio_handler.dart';
import 'package:homespotify_mobile/src/features/player/presentation/player_providers.dart';

import 'support/fake_audio_player.dart';

/// Handler principal factice : n'accepte QUE pause/play (tout autre appel est
/// une fuite de la preview vers le pipeline principal → échec du test).
class _RecordingMainHandler implements HomeSpotifyAudioHandler {
  int pauseCalls = 0;
  int playCalls = 0;

  @override
  Future<void> pause() async => pauseCalls += 1;

  @override
  Future<void> play() async => playCalls += 1;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'la preview ne doit jamais toucher au pipeline principal: '
    '${invocation.memberName}',
  );
}

CatalogPreview preview(String url, {bool requiresSdk = false}) =>
    CatalogPreview(
      provider: 'apple_music',
      url: url,
      durationMs: 30000,
      requiresOfficialSdk: requiresSdk,
      attribution: 'Contenu fourni par Apple Music',
    );

(
  ProviderContainer,
  CatalogPreviewController,
  FakeAudioPlayer,
  _RecordingMainHandler,
)
makeController({bool mainPlaying = false}) {
  final player = FakeAudioPlayer();
  final handler = _RecordingMainHandler();
  final container = ProviderContainer(
    overrides: [
      catalogPreviewPlayerFactoryProvider.overrideWithValue(() => player),
      audioHandlerProvider.overrideWithValue(handler),
      playbackStateProvider.overrideWith(
        (ref) => Stream.value(PlaybackState(playing: mainPlaying)),
      ),
    ],
  );
  // Attend la première valeur du stream de lecture principale.
  container.listen(playbackStateProvider, (_, _) {});
  final controller = container.read(catalogPreviewProvider.notifier);
  return (container, controller, player, handler);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('une seule preview à la fois : la nouvelle coupe l’ancienne', () async {
    final (container, controller, player, _) = makeController();
    await controller.toggle('k1', preview('https://p.example/a.m4a'));
    await controller.toggle('k2', preview('https://p.example/b.m4a'));
    expect(player.loadedUrls, [
      'https://p.example/a.m4a',
      'https://p.example/b.m4a',
    ]);
    expect(container.read(catalogPreviewProvider).activeKey, 'k2');
    container.dispose();
  });

  test('toggle sur la même clé : pause sans rechargement', () async {
    final (container, controller, player, _) = makeController();
    final p = preview('https://p.example/a.m4a');
    await controller.toggle('k1', p);
    expect(player.playing, isTrue);
    await controller.toggle('k1', p);
    expect(player.playing, isFalse);
    expect(player.loadedUrls, hasLength(1));
    container.dispose();
  });

  test(
    'lecteur principal en cours : pause mémorisée, JAMAIS de reprise auto',
    () async {
      final (container, controller, player, handler) = makeController(
        mainPlaying: true,
      );
      await Future<void>.delayed(Duration.zero); // stream primed
      await controller.toggle('k1', preview('https://p.example/a.m4a'));
      expect(handler.pauseCalls, 1);
      expect(
        container.read(catalogPreviewProvider).mainPlaybackInterrupted,
        isTrue,
      );
      // Fin de la preview : la musique principale ne repart PAS seule.
      await controller.stop();
      expect(handler.playCalls, 0);
      expect(
        container.read(catalogPreviewProvider).mainPlaybackInterrupted,
        isTrue,
      );
      // Reprise EXPLICITE uniquement.
      await controller.resumeMainPlayback();
      expect(handler.playCalls, 1);
      expect(
        container.read(catalogPreviewProvider).mainPlaybackInterrupted,
        isFalse,
      );
      expect(player.playing, isFalse);
      container.dispose();
    },
  );

  test('lecteur principal à l’arrêt : aucune pause envoyée', () async {
    final (container, controller, _, handler) = makeController();
    await Future<void>.delayed(Duration.zero);
    await controller.toggle('k1', preview('https://p.example/a.m4a'));
    expect(handler.pauseCalls, 0);
    expect(
      container.read(catalogPreviewProvider).mainPlaybackInterrupted,
      isFalse,
    );
    container.dispose();
  });

  test(
    'preview TIDAL (SDK officiel requis) : jamais lue par just_audio',
    () async {
      final (container, controller, player, _) = makeController();
      await controller.toggle(
        'k1',
        preview('https://tidal.example/x', requiresSdk: true),
      );
      expect(player.loadedUrls, isEmpty);
      expect(container.read(catalogPreviewProvider).activeKey, isNull);
      container.dispose();
    },
  );

  test('stop puis dispose : lecteur arrêté et libéré, état propre', () async {
    final (container, controller, player, _) = makeController();
    await controller.toggle('k1', preview('https://p.example/a.m4a'));
    await controller.stop();
    expect(container.read(catalogPreviewProvider).activeKey, isNull);
    expect(player.playing, isFalse);
    container.dispose();
    expect(player.disposed, isTrue);
  });

  test(
    'la preview ne touche ni queue, ni historique, ni pipeline principal',
    () async {
      // _RecordingMainHandler jette sur TOUT sauf pause/play : si la preview
      // essayait d'ajouter à la queue ou de créer une session d'écoute, ce
      // test exploserait.
      final (container, controller, player, _) = makeController(
        mainPlaying: true,
      );
      await Future<void>.delayed(Duration.zero);
      await controller.toggle('k1', preview('https://p.example/a.m4a'));
      expect(player.playing, isTrue);
      container.dispose();
    },
  );
}
