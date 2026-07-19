import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homespotify_mobile/src/features/discovery/domain/discovery_models.dart';
import 'package:homespotify_mobile/src/features/discovery/presentation/discovery_preview_controller.dart';

import 'support/fake_audio_player.dart';

RecommendationCandidate candidate(int id, {String? previewUrl}) {
  return RecommendationCandidate(
    id: id,
    title: 'Titre $id',
    artist: 'Artiste $id',
    previewUrl: previewUrl,
  );
}

(
  ProviderContainer,
  DiscoveryPreviewController,
  FakeAudioPlayer,
  void Function(),
)
makeController() {
  final player = FakeAudioPlayer();
  var created = 0;
  final container = ProviderContainer(
    overrides: [
      discoveryPreviewPlayerFactoryProvider.overrideWithValue(() {
        created += 1;
        return player;
      }),
    ],
  );
  final controller = container.read(discoveryPreviewProvider.notifier);
  return (
    container,
    controller,
    player,
    () => expect(created, 0, reason: 'aucun lecteur ne doit être créé'),
  );
}

void main() {
  test('aucun lecteur créé sans previewUrl', () async {
    final (container, controller, _, expectNoPlayer) = makeController();
    await controller.toggle(candidate(1));
    expectNoPlayer();
    expect(container.read(discoveryPreviewProvider).candidateId, isNull);
    container.dispose();
  });

  test('lecture puis pause du même extrait', () async {
    final (container, controller, player, _) = makeController();

    final c = candidate(1, previewUrl: 'https://p.example/a.m4a');
    await controller.toggle(c);
    expect(player.loadedUrls, ['https://p.example/a.m4a']);
    expect(player.playing, isTrue);

    await controller.toggle(c); // même carte → pause, pas de rechargement
    expect(player.playing, isFalse);
    expect(player.loadedUrls, hasLength(1));
    container.dispose();
  });

  test('un seul extrait actif : changer de carte coupe le précédent', () async {
    final (container, controller, player, _) = makeController();

    await controller.toggle(
      candidate(1, previewUrl: 'https://p.example/a.m4a'),
    );
    await controller.toggle(
      candidate(2, previewUrl: 'https://p.example/b.m4a'),
    );

    expect(player.stopCalls, greaterThanOrEqualTo(1));
    expect(player.loadedUrls, [
      'https://p.example/a.m4a',
      'https://p.example/b.m4a',
    ]);
    expect(container.read(discoveryPreviewProvider).candidateId, 2);
    container.dispose();
  });

  test(
    'stop() remet l’état à zéro (sortie d’écran, logout, lecture bibliothèque)',
    () async {
      final (container, controller, player, _) = makeController();

      await controller.toggle(
        candidate(1, previewUrl: 'https://p.example/a.m4a'),
      );
      await controller.stop();
      expect(container.read(discoveryPreviewProvider).candidateId, isNull);
      expect(container.read(discoveryPreviewProvider).playing, isFalse);
      expect(player.playing, isFalse);
      container.dispose();
    },
  );

  test('la destruction du provider libère le lecteur (logout)', () async {
    final (container, controller, player, _) = makeController();
    await controller.toggle(
      candidate(1, previewUrl: 'https://p.example/a.m4a'),
    );
    container.dispose();
    expect(player.disposed, isTrue);
  });

  test(
    'armAutoplay démarre la lecture après le délai si la carte reste active',
    () async {
      final (container, controller, player, _) = makeController();
      controller.armAutoplay(
        candidate(1, previewUrl: 'https://p.example/a.m4a'),
      );
      // Avant le délai : rien ne joue encore.
      expect(player.loadedUrls, isEmpty);
      await Future<void>.delayed(
        kPreviewAutoplayDelay + const Duration(milliseconds: 60),
      );
      expect(player.loadedUrls, ['https://p.example/a.m4a']);
      expect(player.playing, isTrue);
      container.dispose();
    },
  );

  test('disarmAutoplay annule la lecture différée (swipe rapide)', () async {
    final (container, controller, player, _) = makeController();
    controller.armAutoplay(candidate(1, previewUrl: 'https://p.example/a.m4a'));
    controller.disarmAutoplay();
    await Future<void>.delayed(
      kPreviewAutoplayDelay + const Duration(milliseconds: 60),
    );
    expect(player.loadedUrls, isEmpty);
    expect(player.playing, isFalse);
    container.dispose();
  });

  test('armAutoplay ne fait rien sans previewUrl', () async {
    final (container, controller, _, expectNoPlayer) = makeController();
    controller.armAutoplay(candidate(1));
    await Future<void>.delayed(
      kPreviewAutoplayDelay + const Duration(milliseconds: 60),
    );
    expectNoPlayer();
    container.dispose();
  });
}
