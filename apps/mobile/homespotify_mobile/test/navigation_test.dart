import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:homespotify_mobile/src/app/navigation.dart';
import 'package:homespotify_mobile/src/features/player/audio/homespotify_audio_handler.dart';
import 'package:homespotify_mobile/src/features/player/presentation/player_providers.dart';
import 'package:homespotify_mobile/src/features/player/presentation/player_screen.dart';
import 'package:homespotify_mobile/src/features/player/presentation/widgets/mini_player.dart';

void main() {
  // Surface type téléphone : la colonne du PlayerScreen dépasse les 600px.
  Future<void> usePhoneSurface(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  playerOverrides() => [
    mediaItemProvider.overrideWith(
      (ref) => Stream.value(
        const MediaItem(id: '1', title: 'Genesis', artist: 'Justice'),
      ),
    ),
    playbackStateProvider.overrideWith(
      (ref) => Stream.value(
        PlaybackState(
          playing: true,
          processingState: AudioProcessingState.ready,
        ),
      ),
    ),
    queueProvider.overrideWith(
      (ref) => Stream.value(const <MediaItem>[
        MediaItem(id: '1', title: 'Genesis', artist: 'Justice'),
      ]),
    ),
    positionDataProvider.overrideWith(
      (ref) => Stream.value(PlayerPositionData.zero),
    ),
    volumeProvider.overrideWith((ref) => Stream.value(1.0)),
  ];

  GoRouter playerRouter() => GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const Scaffold(body: Text('bibliotheque')),
      ),
      GoRoute(path: '/player', builder: (_, _) => const PlayerScreen()),
    ],
  );

  testWidgets('openPlayer : ne pousse jamais /player en double', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, _) => const Text('bibliotheque')),
        GoRoute(
          path: '/player',
          builder: (_, _) => const Text('ecran lecteur'),
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    // Contexte de la route racine, conservé même une fois /player poussé.
    final libContext = tester.element(find.text('bibliotheque'));

    openPlayer(libContext);
    await tester.pumpAndSettle();
    expect(find.text('ecran lecteur'), findsOneWidget);

    // Second appel alors que /player est déjà au sommet (ex. push différé
    // après la préparation asynchrone d'une file) : ne doit rien empiler.
    openPlayer(libContext);
    await tester.pumpAndSettle();
    expect(find.text('ecran lecteur'), findsOneWidget);

    // Un seul retour suffit pour revenir à la racine.
    router.pop();
    await tester.pumpAndSettle();
    expect(find.text('bibliotheque'), findsOneWidget);
    expect(router.canPop(), isFalse);
  });

  testWidgets(
    'retour système : un seul appui ramène du lecteur à la bibliothèque',
    (tester) async {
      await usePhoneSurface(tester);
      final router = playerRouter();
      await tester.pumpWidget(
        ProviderScope(
          overrides: playerOverrides(),
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      // openPlayer garantit une instance unique de /player (testé plus haut).
      router.push('/player');
      await tester.pumpAndSettle();
      expect(find.text('EN LECTURE'), findsOneWidget);

      // Bouton retour Android.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('bibliotheque'), findsOneWidget);
      expect(find.text('EN LECTURE'), findsNothing);
    },
  );

  testWidgets(
    'retour lecteur : revient à l’écran qui l’a ouvert, pas à la racine',
    (tester) async {
      await usePhoneSurface(tester);
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(body: Text('bibliotheque')),
          ),
          GoRoute(
            path: '/albums',
            builder: (_, _) => const Scaffold(body: Text('ecran albums')),
          ),
          GoRoute(path: '/player', builder: (_, _) => const PlayerScreen()),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: playerOverrides(),
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      router.push('/albums');
      await tester.pumpAndSettle();
      router.push('/player');
      await tester.pumpAndSettle();
      expect(find.text('EN LECTURE'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('ecran albums'), findsOneWidget);
      expect(find.text('EN LECTURE'), findsNothing);
    },
  );

  testWidgets(
    'mini-player : les boutons ne poussent jamais /player, le fond oui',
    (tester) async {
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(
              body: Text('bibliotheque'),
              bottomNavigationBar: MiniPlayer(),
            ),
          ),
          GoRoute(
            path: '/player',
            builder: (_, _) => const Text('ecran lecteur'),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            mediaItemProvider.overrideWith(
              (ref) => Stream.value(
                const MediaItem(id: '1', title: 'Genesis', artist: 'Justice'),
              ),
            ),
            // Busy : play/pause désactivé (spinner) ; une seule piste en
            // file : suivant désactivé. C'était le cas où les taps
            // traversaient vers l'ouverture du lecteur complet.
            playbackStateProvider.overrideWith(
              (ref) => Stream.value(
                PlaybackState(
                  playing: false,
                  processingState: AudioProcessingState.loading,
                ),
              ),
            ),
            queueProvider.overrideWith(
              (ref) => Stream.value(const <MediaItem>[
                MediaItem(id: '1', title: 'Genesis', artist: 'Justice'),
              ]),
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      // pump manuel : le spinner du mini-player anime en continu,
      // pumpAndSettle ne convergerait jamais. Deux pumps : le premier livre
      // mediaItem (le mini-player s'abonne alors au reste), le second livre
      // l'état busy.
      await tester.pump();
      await tester.pump();

      await tester.tap(
        find.byType(CircularProgressIndicator),
        warnIfMissed: false,
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('ecran lecteur'), findsNothing);

      await tester.tap(find.byIcon(Icons.skip_previous_rounded));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('ecran lecteur'), findsNothing);

      await tester.tap(find.byIcon(Icons.skip_next_rounded));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('ecran lecteur'), findsNothing);

      // Seule la zone pochette/titres ouvre le lecteur complet.
      await tester.tap(find.text('Genesis'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('ecran lecteur'), findsOneWidget);
    },
  );

  testWidgets('bouton retour UI : un seul tap ramène à la bibliothèque', (
    tester,
  ) async {
    await usePhoneSurface(tester);
    final router = playerRouter();
    await tester.pumpWidget(
      ProviderScope(
        overrides: playerOverrides(),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    router.push('/player');
    await tester.pumpAndSettle();
    expect(find.text('EN LECTURE'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();

    expect(find.text('bibliotheque'), findsOneWidget);
    expect(find.text('EN LECTURE'), findsNothing);
  });
}
