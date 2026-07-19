import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homespotify_mobile/src/app/route_observer.dart';
import 'package:homespotify_mobile/src/features/discovery/application/discovery_settings.dart';
import 'package:homespotify_mobile/src/features/discovery/data/discovery_api.dart';
import 'package:homespotify_mobile/src/features/discovery/domain/discovery_models.dart';
import 'package:homespotify_mobile/src/features/discovery/presentation/discover_deck_controller.dart';
import 'package:homespotify_mobile/src/features/discovery/presentation/discover_screen.dart';
import 'package:homespotify_mobile/src/features/discovery/presentation/discovery_preview_controller.dart';
import 'package:homespotify_mobile/src/features/discovery/presentation/music_requests_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_audio_player.dart';
import 'support/fake_discovery.dart';

RecommendationCandidate candidate(
  int id, {
  String? title,
  String? artist,
  String? previewUrl,
}) {
  return RecommendationCandidate(
    id: id,
    title: title ?? 'Titre $id',
    artist: artist ?? 'Artiste $id',
    album: 'Album $id',
    previewUrl: previewUrl,
    reason: id == 1
        ? 'Parce que Artiste 1 est déjà dans ta bibliothèque'
        : null,
  );
}

MusicRequest request(int id, MusicRequestStatus status, {String? ownerNote}) {
  return MusicRequest(
    id: id,
    candidateId: id,
    title: 'Titre $id',
    artist: 'Artiste $id',
    status: status,
    ownerNote: ownerNote,
  );
}

Widget wrap(FakeDiscoveryRepository fake, Widget child) {
  return ProviderScope(
    overrides: [discoveryApiProvider.overrideWithValue(fake)],
    child: MaterialApp(home: child),
  );
}

/// Monte DiscoverScreen comme une VRAIE route poussée, sous un Navigator équipé
/// du [routeObserver] global — indispensable pour tester la visibilité de route
/// (didPushNext/didPopNext). Retourne le navigateur, le conteneur (survivant) et
/// le faux lecteur.
Future<(GlobalKey<NavigatorState>, ProviderContainer, FakeAudioPlayer)>
pumpDiscoverRouted(
  WidgetTester tester, {
  List<RecommendationCandidate>? recommendations,
}) async {
  final player = FakeAudioPlayer();
  final fake = FakeDiscoveryRepository(
    recommendations:
        recommendations ??
        [candidate(1, previewUrl: 'https://p.example/1.m4a')],
  );
  final container = ProviderContainer(
    overrides: [
      discoveryApiProvider.overrideWithValue(fake),
      discoveryPreviewPlayerFactoryProvider.overrideWithValue(() => player),
    ],
  );
  addTearDown(container.dispose);

  final navKey = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        navigatorKey: navKey,
        navigatorObservers: [routeObserver],
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    ),
  );
  navKey.currentState!.push(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/discover'),
      builder: (_) => const DiscoverScreen(),
    ),
  );
  await tester.pumpAndSettle();
  return (navKey, container, player);
}

/// Route factice « obscurcissante » (simule /requests, /player, etc.).
Route<void> _coveringRoute([String label = 'Cover']) => MaterialPageRoute<void>(
  settings: RouteSettings(name: '/$label'),
  builder: (_) => Scaffold(body: Text(label)),
);

void main() {
  group('MusicRequestStatus', () {
    test('mappe les statuts backend vers des libellés métier lisibles', () {
      expect(MusicRequestStatus.fromWire('SENT').label, 'Demande envoyée');
      expect(
        MusicRequestStatus.fromWire('REVIEWING').label,
        'En cours de traitement',
      );
      expect(
        MusicRequestStatus.fromWire('SEARCHING_MANUALLY').label,
        'En cours de traitement',
      );
      expect(
        MusicRequestStatus.fromWire('PARTIALLY_COMPLETED').label,
        'Ajout partiel',
      );
      expect(
        MusicRequestStatus.fromWire('COMPLETED').label,
        'Ajoutée à votre bibliothèque',
      );
      expect(
        MusicRequestStatus.fromWire('inconnu-du-futur').label,
        'Statut inconnu',
      );
    });

    test('annulable uniquement avant import/complétion', () {
      expect(MusicRequestStatus.sent.isCancellable, isTrue);
      expect(MusicRequestStatus.reviewing.isCancellable, isTrue);
      expect(MusicRequestStatus.approved.isCancellable, isTrue);
      expect(MusicRequestStatus.searchingManually.isCancellable, isTrue);
      expect(MusicRequestStatus.importing.isCancellable, isFalse);
      expect(MusicRequestStatus.completed.isCancellable, isFalse);
      expect(MusicRequestStatus.cancelled.isCancellable, isFalse);
      expect(MusicRequestStatus.rejected.isCancellable, isFalse);
    });
  });

  group('RecommendationPage', () {
    test('parse items, curseur et reasonCode', () {
      final page = RecommendationPage.fromJson({
        'items': [
          {
            'id': 1,
            'title': 'T',
            'artist': 'A',
            'reason': 'Parce que tu écoutes souvent A',
            'reasonCode': 'TOP_ARTIST',
          },
        ],
        'nextCursor': '10',
      });
      expect(page.items.single.reasonCode, 'TOP_ARTIST');
      expect(page.nextCursor, '10');
    });
  });

  group('DiscoverScreen', () {
    testWidgets('affiche la carte du haut ; les 2 suivantes sont pré-rendues', (
      tester,
    ) async {
      final fake = FakeDiscoveryRepository(
        recommendations: [
          candidate(1),
          candidate(2),
          candidate(3),
          candidate(4),
        ],
      );
      await tester.pumpWidget(wrap(fake, const DiscoverScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Titre 1'), findsOneWidget);
      expect(find.textContaining('Artiste 1'), findsWidgets);
      expect(
        find.text('Parce que Artiste 1 est déjà dans ta bibliothèque'),
        findsOneWidget,
      );
      // Pré-rendu : les cartes 2 et 3 existent déjà dans l'arbre (sous la
      // carte active), la carte 4 n'est pas encore construite.
      expect(find.text('Titre 2'), findsOneWidget);
      expect(find.text('Titre 3'), findsOneWidget);
      expect(find.text('Titre 4'), findsNothing);
    });

    testWidgets('skeleton bref pendant le chargement initial', (tester) async {
      final fake = FakeDiscoveryRepository(
        recommendations: [candidate(1)],
        fetchDelay: const Duration(milliseconds: 300),
      );
      await tester.pumpWidget(wrap(fake, const DiscoverScreen()));
      await tester.pump(const Duration(milliseconds: 50));
      // Pas encore de carte : squelette visible, pas d'écran vide ni d'erreur.
      expect(find.text('Titre 1'), findsNothing);
      expect(find.textContaining('Aucune recommandation'), findsNothing);
      await tester.pumpAndSettle();
      expect(find.text('Titre 1'), findsOneWidget);
    });

    testWidgets('bouton demande : dialogue de confirmation puis envoi', (
      tester,
    ) async {
      final fake = FakeDiscoveryRepository(recommendations: [candidate(1)]);
      await tester.pumpWidget(wrap(fake, const DiscoverScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Envoyer une demande'));
      await tester.pumpAndSettle();
      expect(find.text('Envoyer une demande ?'), findsOneWidget);
      // Refus : rien n'est envoyé, la carte reste.
      await tester.tap(find.text('Annuler'));
      await tester.pumpAndSettle();
      expect(fake.createdRequests, isEmpty);
      expect(find.text('Titre 1'), findsOneWidget);

      // Acceptation : demande créée, carte retirée.
      await tester.tap(find.byTooltip('Envoyer une demande'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Envoyer la demande'));
      await tester.pumpAndSettle();
      expect(fake.createdRequests, [1]);
      expect(find.text('Titre 1'), findsNothing);
    });

    testWidgets('demande réussie : overlay « Demande envoyée » puis nettoyage '
        'automatique (plus de SnackBar blanche)', (tester) async {
      final fake = FakeDiscoveryRepository(
        recommendations: [candidate(1), candidate(2)],
      );
      await tester.pumpWidget(wrap(fake, const DiscoverScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Envoyer une demande'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Envoyer la demande'));
      await tester.pump(); // ferme le dialogue + résout l'appel
      await tester.pump(const Duration(milliseconds: 300)); // overlay en cours

      // Overlay premium visible ; l'ancienne SnackBar blanche a disparu.
      expect(find.text('Demande envoyée'), findsOneWidget);
      expect(find.text('Titre 1 — Artiste 1'), findsOneWidget);
      expect(find.textContaining('Demande envoyée pour'), findsNothing);
      expect(fake.createdRequests, [1]);

      // Fin de l'animation → l'overlay se retire tout seul (aucune fuite).
      await tester.pumpAndSettle();
      expect(find.text('Demande envoyée'), findsNothing);
      expect(find.text('Titre 2'), findsOneWidget);
    });

    testWidgets('demande échouée : rollback visuel + SnackBar, AUCUN overlay '
        'de succès', (tester) async {
      final fake = FakeDiscoveryRepository(recommendations: [candidate(1)]);
      fake.nextCreateError = const DiscoveryApiException(
        'Serveur indisponible.',
      );
      await tester.pumpWidget(wrap(fake, const DiscoverScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Envoyer une demande'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Envoyer la demande'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Demande envoyée'), findsNothing);
      expect(find.text('Titre 1'), findsOneWidget); // rollback : carte en place
      expect(find.text('Serveur indisponible.'), findsOneWidget);
      expect(fake.createdRequests, isEmpty);
      await tester.pumpAndSettle();
    });

    testWidgets('extrait coupé AVANT la transition ; le suivant ne démarre '
        'qu\'après l\'overlay (carte stable)', (tester) async {
      final player = FakeAudioPlayer();
      final fake = FakeDiscoveryRepository(
        recommendations: [
          candidate(1, previewUrl: 'https://p.example/1.m4a'),
          candidate(2, previewUrl: 'https://p.example/2.m4a'),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            discoveryApiProvider.overrideWithValue(fake),
            discoveryPreviewPlayerFactoryProvider.overrideWithValue(
              () => player,
            ),
          ],
          child: const MaterialApp(home: DiscoverScreen()),
        ),
      );
      await tester.pumpAndSettle();

      // Autoplay de la carte 1 après le délai.
      await tester.pump(
        kPreviewAutoplayDelay + const Duration(milliseconds: 80),
      );
      expect(player.loadedUrls, ['https://p.example/1.m4a']);
      final stopsBefore = player.stopCalls;

      await tester.tap(find.byTooltip('Envoyer une demande'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Envoyer la demande'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Extrait coupé, overlay visible, la carte 2 n'a PAS encore démarré.
      expect(player.stopCalls, greaterThan(stopsBefore));
      expect(find.text('Demande envoyée'), findsOneWidget);
      expect(player.loadedUrls, ['https://p.example/1.m4a']);

      // Fin de l'overlay (retrait auto) → l'autoplay de la carte 2 est réarmé.
      await tester.pumpAndSettle();
      expect(find.text('Demande envoyée'), findsNothing);
      // Le délai d'autoplay écoulé sur la carte stable → son extrait démarre.
      await tester.pump(
        kPreviewAutoplayDelay + const Duration(milliseconds: 80),
      );
      expect(player.loadedUrls, [
        'https://p.example/1.m4a',
        'https://p.example/2.m4a',
      ]);
      // Le démontage automatique de fin de test coupe l'extrait proprement via
      // deactivate() — aucune assertion de cycle de vie (cf. test dédié).
    });

    testWidgets('quitter l\'écran pendant un extrait actif : arrêt immédiat, '
        'unmount propre (aucune assertion Riverpod), aucun timer en fuite', (
      tester,
    ) async {
      final player = FakeAudioPlayer();
      final fake = FakeDiscoveryRepository(
        recommendations: [candidate(1, previewUrl: 'https://p.example/1.m4a')],
      );
      // Conteneur EXTERNE partagé : il survit au pop de route, ce qui permet de
      // vérifier l'état du lecteur après la navigation.
      final container = ProviderContainer(
        overrides: [
          discoveryApiProvider.overrideWithValue(fake),
          discoveryPreviewPlayerFactoryProvider.overrideWithValue(() => player),
        ],
      );
      addTearDown(container.dispose);

      final navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            navigatorKey: navKey,
            home: const Scaffold(body: SizedBox.shrink()),
          ),
        ),
      );
      // Pousse l'écran Découvrir comme une vraie route.
      navKey.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const DiscoverScreen()),
      );
      await tester.pumpAndSettle();

      // Extrait actif sur la carte 1.
      await tester.pump(
        kPreviewAutoplayDelay + const Duration(milliseconds: 80),
      );
      expect(player.playing, isTrue);
      expect(container.read(discoveryPreviewProvider).candidateId, 1);

      // Retour système : PopScope intercepte le pop comme un ÉVÉNEMENT et coupe
      // l'extrait. Sans le correctif, dispose()/deactivate() lançait une
      // assertion Riverpod (mutation d'un provider observé pendant l'unmount).
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      // Arrêt IMMÉDIAT de l'extrait, unmount PROPRE (aucune exception), et le
      // lecteur a bien reçu stop().
      expect(tester.takeException(), isNull);
      expect(container.read(discoveryPreviewProvider).candidateId, isNull);
      expect(container.read(discoveryPreviewProvider).playing, isFalse);
      expect(player.stopCalls, greaterThan(0));
    });

    testWidgets('sondage adaptatif : s\'arrête pile à l\'état terminal, aucun '
        'timer en fuite', (tester) async {
      final fake = FakeDiscoveryRepository(
        recommendations: [candidate(1)],
        refreshingPolls: 2, // 2 sondes « en cours » puis terminal
      );
      await tester.pumpWidget(wrap(fake, const DiscoverScreen()));
      await tester.pumpAndSettle();
      expect(
        fake.statusCalls,
        0,
      ); // file non vide : aucun refresh au chargement

      await tester.tap(find.byTooltip('Actualiser les recommandations'));
      await tester.pump();
      // Le sondage adaptatif (800ms, 1500ms, 1500ms…) est déroulé par
      // pumpAndSettle jusqu'à l'état terminal, puis s'arrête.
      await tester.pumpAndSettle();
      expect(fake.statusCalls, 3);
    });

    testWidgets('bouton pas pour moi : DISLIKE et carte suivante', (
      tester,
    ) async {
      final fake = FakeDiscoveryRepository(
        recommendations: [candidate(1), candidate(2)],
      );
      await tester.pumpWidget(wrap(fake, const DiscoverScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Pas pour moi'));
      await tester.pumpAndSettle();
      expect(fake.actions, contains((1, RecommendationSwipeAction.dislike)));
      expect(find.text('Titre 2'), findsOneWidget);
      expect(find.text('Titre 1'), findsNothing);
    });

    testWidgets('rollback : si le DISLIKE échoue, la carte reste en place', (
      tester,
    ) async {
      final fake = FakeDiscoveryRepository(
        recommendations: [candidate(1), candidate(2)],
      );
      fake.nextActionError = const DiscoveryApiException(
        'Serveur indisponible.',
      );
      await tester.pumpWidget(wrap(fake, const DiscoverScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Pas pour moi'));
      await tester.pumpAndSettle();
      // La carte 1 est toujours en tête (rollback), l'erreur est affichée.
      expect(find.text('Titre 1'), findsOneWidget);
      expect(find.text('Serveur indisponible.'), findsOneWidget);
      expect(fake.actions, isEmpty);
    });

    testWidgets('bouton passer : SKIP sans dialogue', (tester) async {
      final fake = FakeDiscoveryRepository(
        recommendations: [candidate(1), candidate(2)],
      );
      await tester.pumpWidget(wrap(fake, const DiscoverScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Passer'));
      await tester.pumpAndSettle();
      expect(fake.actions, contains((1, RecommendationSwipeAction.skip)));
      expect(fake.createdRequests, isEmpty);
      expect(find.text('Titre 2'), findsOneWidget);
    });

    testWidgets('file vide : état vide propre + UNE régénération automatique', (
      tester,
    ) async {
      final fake = FakeDiscoveryRepository();
      await tester.pumpWidget(wrap(fake, const DiscoverScreen()));
      await tester.pumpAndSettle();
      expect(find.textContaining('Aucune recommandation'), findsOneWidget);
      expect(find.text('Actualiser les recommandations'), findsWidgets);
      expect(fake.refreshCount, 1);
    });

    testWidgets('le paquet survit à une reconstruction complète de l’écran', (
      tester,
    ) async {
      final fake = FakeDiscoveryRepository(
        recommendations: [candidate(1), candidate(2)],
      );
      final overrides = [discoveryApiProvider.overrideWithValue(fake)];
      await tester.pumpWidget(
        ProviderScope(
          overrides: overrides,
          child: MaterialApp(home: DiscoverScreen(key: UniqueKey())),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Pas pour moi'));
      await tester.pumpAndSettle();
      expect(find.text('Titre 2'), findsOneWidget);
      final fetchesBefore = fake.fetchCount;

      // L'écran est ENTIÈREMENT recréé (nouvelle clé) : l'état du paquet,
      // porté par Riverpod, ne repart pas de zéro.
      await tester.pumpWidget(
        ProviderScope(
          overrides: overrides,
          child: MaterialApp(home: DiscoverScreen(key: UniqueKey())),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Titre 2'), findsOneWidget);
      expect(find.text('Titre 1'), findsNothing);
      expect(fake.fetchCount, fetchesBefore);
    });
  });

  group('DiscoverScreen — visibilité de route (RouteAware)', () {
    testWidgets(
      'push /requests par-dessus : l\'extrait s\'arrête IMMÉDIATEMENT',
      (tester) async {
        final (navKey, container, player) = await pumpDiscoverRouted(tester);
        // Extrait actif sur la carte visible.
        await tester.pump(
          kPreviewAutoplayDelay + const Duration(milliseconds: 80),
        );
        expect(player.playing, isTrue);
        final stopsBefore = player.stopCalls;

        // Une route couvre Découvrir → didPushNext.
        navKey.currentState!.push(_coveringRoute('requests'));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull); // zéro assertion Riverpod
        expect(player.stopCalls, greaterThan(stopsBefore));
        expect(container.read(discoveryPreviewProvider).candidateId, isNull);
        expect(container.read(discoveryPreviewProvider).playing, isFalse);
      },
    );

    testWidgets('retour depuis la route couvrante : réarme UNE fois (pas de '
        'double autoplay)', (tester) async {
      final (navKey, container, player) = await pumpDiscoverRouted(tester);
      await tester.pump(
        kPreviewAutoplayDelay + const Duration(milliseconds: 80),
      );
      expect(player.loadedUrls, ['https://p.example/1.m4a']);

      navKey.currentState!.push(_coveringRoute('requests'));
      await tester.pumpAndSettle();
      expect(player.playing, isFalse);

      // Retour sur Découvrir → didPopNext → réarmement conditionnel unique.
      navKey.currentState!.pop();
      await tester.pumpAndSettle();
      await tester.pump(
        kPreviewAutoplayDelay + const Duration(milliseconds: 80),
      );

      expect(tester.takeException(), isNull);
      // La carte 1 a rejoué UNE SEULE FOIS de plus (pas de double lecture) :
      // un seul rechargement supplémentaire de la même URL.
      expect(player.loadedUrls, [
        'https://p.example/1.m4a',
        'https://p.example/1.m4a',
      ]);
      expect(container.read(discoveryPreviewProvider).candidateId, 1);

      // Nettoyage propre avant démontage (arrêt via événement).
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
    });

    testWidgets('push d\'une route quelconque : l\'extrait s\'arrête', (
      tester,
    ) async {
      final (navKey, container, player) = await pumpDiscoverRouted(tester);
      await tester.pump(
        kPreviewAutoplayDelay + const Duration(milliseconds: 80),
      );
      final stopsBefore = player.stopCalls;

      navKey.currentState!.push(_coveringRoute('player'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(player.stopCalls, greaterThan(stopsBefore));
      expect(container.read(discoveryPreviewProvider).playing, isFalse);
    });

    testWidgets(
      'retour arrière système (pop de Découvrir) : l\'extrait s\'arrête',
      (tester) async {
        final (_, container, player) = await pumpDiscoverRouted(tester);
        await tester.pump(
          kPreviewAutoplayDelay + const Duration(milliseconds: 80),
        );
        expect(player.playing, isTrue);

        await tester.binding.handlePopRoute(); // retour système → PopScope
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(container.read(discoveryPreviewProvider).candidateId, isNull);
        expect(player.stopCalls, greaterThan(0));
      },
    );

    testWidgets('pop programmatique (go vers un ancêtre) : l\'extrait s\'arrête '
        'via didPop', (tester) async {
      final (navKey, container, player) = await pumpDiscoverRouted(tester);
      await tester.pump(
        kPreviewAutoplayDelay + const Duration(milliseconds: 80),
      );
      expect(player.playing, isTrue);

      // Retrait impératif de la route (équivalent d'un go/pop qui ne passe pas
      // toujours par le PopScope) : couvert par RouteAware.didPop.
      navKey.currentState!.pop();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(container.read(discoveryPreviewProvider).candidateId, isNull);
      expect(player.stopCalls, greaterThan(0));
    });

    testWidgets('logout (invalidation des providers) : l\'extrait s\'arrête et '
        'le lecteur est libéré', (tester) async {
      final (_, container, player) = await pumpDiscoverRouted(tester);
      await tester.pump(
        kPreviewAutoplayDelay + const Duration(milliseconds: 80),
      );
      expect(player.playing, isTrue);

      // Équivaut à AuthController._invalidatePersonalProviders (go /login).
      container.invalidate(discoveryPreviewProvider);
      container.invalidate(discoverDeckProvider);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(player.disposed, isTrue); // lecteur libéré, aucun orphelin
    });

    testWidgets('arrière-plan puis premier plan : récupération saine, aucune '
        'lecture pendant l\'arrière-plan', (tester) async {
      final (_, container, player) = await pumpDiscoverRouted(tester);
      await tester.pump(
        kPreviewAutoplayDelay + const Duration(milliseconds: 80),
      );
      expect(player.playing, isTrue);

      // Arrière-plan : l'extrait se coupe (didChangeAppLifecycleState).
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      expect(player.playing, isFalse);

      // Premier plan : pas de crash ; la lecture ne redémarre pas toute seule
      // (le réarmement passe par la stabilisation de carte, pas le resume).
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(container.read(discoveryPreviewProvider).playing, isFalse);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
    });

    testWidgets('volet Android : inactive puis resumed conserve exactement le '
        'même extrait', (tester) async {
      final (_, container, player) = await pumpDiscoverRouted(tester);
      await tester.pump(
        kPreviewAutoplayDelay + const Duration(milliseconds: 80),
      );
      expect(player.playing, isTrue);
      final stopsBefore = player.stopCalls;
      final loadsBefore = List<String>.of(player.loadedUrls);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(player.playing, isTrue);
      expect(player.stopCalls, stopsBefore);
      expect(player.loadedUrls, loadsBefore);
      expect(container.read(discoveryPreviewProvider).candidateId, 1);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
    });

    testWidgets('inactive puis hidden coupe instantanément l\'extrait', (
      tester,
    ) async {
      final (_, container, player) = await pumpDiscoverRouted(tester);
      await tester.pump(
        kPreviewAutoplayDelay + const Duration(milliseconds: 80),
      );
      final stopsBefore = player.stopCalls;

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(player.playing, isTrue);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();

      expect(player.playing, isFalse);
      expect(player.stopCalls, greaterThan(stopsBefore));
      expect(container.read(discoveryPreviewProvider).candidateId, isNull);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(player.playing, isFalse);
    });
  });

  group('MusicRequestsScreen', () {
    testWidgets('affiche les statuts métier lisibles et la note du OWNER', (
      tester,
    ) async {
      final fake = FakeDiscoveryRepository(
        requests: [
          request(1, MusicRequestStatus.sent),
          request(
            2,
            MusicRequestStatus.reviewing,
            ownerNote: 'Je cherche le CD',
          ),
          request(3, MusicRequestStatus.completed),
          request(4, MusicRequestStatus.rejected),
        ],
      );
      await tester.pumpWidget(wrap(fake, const MusicRequestsScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Demande envoyée'), findsOneWidget);
      expect(find.text('En cours de traitement'), findsOneWidget);
      expect(find.text('Ajoutée à votre bibliothèque'), findsOneWidget);
      expect(find.text('Demande refusée'), findsOneWidget);
      expect(find.textContaining('Recherche manuelle'), findsNothing);
      expect(
        find.text('Note du propriétaire : Je cherche le CD'),
        findsOneWidget,
      );
    });

    testWidgets('annulation : uniquement avant import, avec confirmation', (
      tester,
    ) async {
      final fake = FakeDiscoveryRepository(
        requests: [
          request(1, MusicRequestStatus.sent),
          request(2, MusicRequestStatus.importing),
        ],
      );
      await tester.pumpWidget(wrap(fake, const MusicRequestsScreen()));
      await tester.pumpAndSettle();

      // Une seule demande annulable → un seul bouton d'annulation.
      expect(find.byTooltip('Annuler la demande'), findsOneWidget);

      await tester.tap(find.byTooltip('Annuler la demande'));
      await tester.pumpAndSettle();
      expect(find.text('Annuler la demande ?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Annuler la demande'));
      await tester.pumpAndSettle();

      expect(fake.cancelledRequests, [1]);
      expect(find.text('Demande annulée'), findsOneWidget);
    });

    testWidgets('le formulaire propose TRACK, ALBUM et PLAYLIST', (
      tester,
    ) async {
      final fake = FakeDiscoveryRepository();
      await tester.pumpWidget(wrap(fake, const MusicRequestsScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Nouvelle demande'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<MusicRequestType>));
      await tester.pumpAndSettle();

      expect(find.text('Morceau'), findsWidgets);
      expect(find.text('Album'), findsWidgets);
      expect(find.text('Playlist'), findsOneWidget);
      expect(find.textContaining('traitement manuel'), findsNothing);
    });

    testWidgets('liste vide : message d\'invitation vers Découvrir', (
      tester,
    ) async {
      final fake = FakeDiscoveryRepository();
      await tester.pumpWidget(wrap(fake, const MusicRequestsScreen()));
      await tester.pumpAndSettle();
      expect(find.textContaining('Aucune demande'), findsOneWidget);
    });
  });

  group('DiscoverySettings', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('valeur par défaut : autoplay activé', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // Déclenche le build (charge les prefs en tâche de fond) puis laisse le
      // microtask se résoudre.
      container.read(discoverySettingsProvider);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final settings = container.read(discoverySettingsProvider);
      expect(settings.autoplayPreviews, isTrue);
    });

    test('le réglage autoplay est persisté', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(discoverySettingsProvider.notifier);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await controller.setAutoplayPreviews(false);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('discovery.autoplay_previews'), isFalse);
    });
  });
}
