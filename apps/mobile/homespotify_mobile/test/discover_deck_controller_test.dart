import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homespotify_mobile/src/features/discovery/data/discovery_api.dart';
import 'package:homespotify_mobile/src/features/discovery/domain/discovery_models.dart';
import 'package:homespotify_mobile/src/features/discovery/presentation/discover_deck_controller.dart';

import 'package:homespotify_mobile/src/features/remote_download/data/remote_download_api.dart';

import 'support/fake_discovery.dart';
import 'support/fake_remote_download.dart';

RecommendationCandidate candidate(int id) {
  return RecommendationCandidate(
    id: id,
    title: 'Titre $id',
    artist: 'Artiste $id',
  );
}

(ProviderContainer, DiscoverDeckController) makeController(
  FakeDiscoveryRepository fake, {
  FakeRemoteDownloadRepository? downloads,
}) {
  final container = ProviderContainer(
    overrides: [
      discoveryApiProvider.overrideWithValue(fake),
      remoteDownloadApiProvider.overrideWithValue(
        downloads ?? FakeRemoteDownloadRepository(),
      ),
    ],
  );
  return (container, container.read(discoverDeckProvider.notifier));
}

void main() {
  test('load charge la première page et mémorise le curseur', () async {
    final fake = FakeDiscoveryRepository(
      recommendations: [for (var i = 1; i <= 20; i += 1) candidate(i)],
    );
    final (container, controller) = makeController(fake);
    await controller.load();
    final state = container.read(discoverDeckProvider);
    expect(state.deck, hasLength(15));
    expect(state.nextCursor, isNotNull);
    expect(state.loadedOnce, isTrue);
    container.dispose();
  });

  test(
    'advance précharge la page suivante quand le paquet devient court',
    () async {
      final fake = FakeDiscoveryRepository(
        recommendations: [for (var i = 1; i <= 8; i += 1) candidate(i)],
        pageSize: 5,
      );
      final (container, controller) = makeController(fake);
      await controller.load();
      expect(container.read(discoverDeckProvider).deck, hasLength(5));

      controller.advance(); // 4 restantes ≤ seuil → préchargement
      await Future<void>.delayed(Duration.zero);
      final state = container.read(discoverDeckProvider);
      expect(state.deck.map((c) => c.id), [2, 3, 4, 5, 6, 7, 8]);
      expect(state.nextCursor, isNull);
      container.dispose();
    },
  );

  test('verrou de swipe : pas de double DISLIKE concurrent', () async {
    final fake = FakeDiscoveryRepository(recommendations: [candidate(1)]);
    final (container, controller) = makeController(fake);
    await controller.load();

    final top = container.read(discoverDeckProvider).top!;
    final first = controller.dislike(top);
    final second = controller.dislike(top);
    expect(await second, isFalse); // verrouillé pendant la première action
    expect(await first, isTrue);
    expect(fake.actions, hasLength(1));
    container.dispose();
  });

  test(
    'échec backend : dislike retourne false et le paquet est inchangé',
    () async {
      final fake = FakeDiscoveryRepository(
        recommendations: [candidate(1), candidate(2)],
      );
      fake.nextActionError = const DiscoveryApiException('Panne.');
      final (container, controller) = makeController(fake);
      await controller.load();

      expect(
        await controller.dislike(container.read(discoverDeckProvider).top!),
        isFalse,
      );
      expect(container.read(discoverDeckProvider).deck.first.id, 1);
      expect(controller.takeError(), 'Panne.');
      // Erreur consommée une seule fois.
      expect(container.read(discoverDeckProvider).error, isNull);
      container.dispose();
    },
  );

  test('installer envoie l’identité du candidat, sans aucune demande', () async {
    final fake = FakeDiscoveryRepository(recommendations: [candidate(1)]);
    final downloads = FakeRemoteDownloadRepository();
    final (container, controller) = makeController(fake, downloads: downloads);
    await controller.load();
    expect(
      await controller.install(container.read(discoverDeckProvider).top!),
      isTrue,
    );
    expect(downloads.calls.single.title, 'Titre 1');
    expect(downloads.calls.single.artist, 'Artiste 1');
    container.dispose();
  });

  test('téléchargement déjà en cours : la carte est quand même retirée', () async {
    final fake = FakeDiscoveryRepository(recommendations: [candidate(1)]);
    final downloads = FakeRemoteDownloadRepository(
      failWith: const RemoteDownloadException(
        'Ce lien est déjà en cours de téléchargement.',
        statusCode: 409,
      ),
    );
    final (container, controller) = makeController(fake, downloads: downloads);
    await controller.load();
    expect(
      await controller.install(container.read(discoverDeckProvider).top!),
      isTrue,
    );
    container.dispose();
  });

  test('dispose annule immédiatement le timer de polling sans fuite', () async {
    final fake = FakeDiscoveryRepository(statusRefreshing: true);
    final (container, controller) = makeController(fake);
    final refresh = controller.refresh();
    await Future<void>.delayed(Duration.zero);
    container.dispose();
    await expectLater(refresh, completes);
  });
}
