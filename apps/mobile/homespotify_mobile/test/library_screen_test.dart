import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:homespotify_mobile/src/features/library/data/library_api.dart';
import 'package:homespotify_mobile/src/features/auth/application/auth_controller.dart';
import 'package:homespotify_mobile/src/features/library/domain/track.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_playback_controller.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_screen.dart';
import 'package:homespotify_mobile/src/features/player/presentation/player_providers.dart';
import 'package:homespotify_mobile/src/features/player/audio/homespotify_audio_handler.dart';

import 'support/fake_auth.dart';
import 'support/fake_library_repositories.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_favorites.dart';

void main() {
  const track = Track(
    id: 1,
    title: 'Genesis',
    artist: 'Justice',
    album: 'Cross',
    hasCover: false,
    durationSeconds: 200,
    extension: '.flac',
    mimeType: 'audio/flac',
    quality: TrackQuality(
      sampleRate: 44100,
      bitDepth: 16,
      status: 'lossless_verifie',
    ),
  );

  baseOverrides({required FutureOr<List<Track>> Function() library}) {
    return [
      ...authOverrides(
        state: AuthState(AuthStatus.authenticated, user: makeUser()),
      ),
      libraryProvider.overrideWith((ref) => Future.value(library())),
      mediaItemProvider.overrideWith((ref) => const Stream<MediaItem?>.empty()),
      playbackStateProvider.overrideWith(
        (ref) => const Stream<PlaybackState>.empty(),
      ),
      queueProvider.overrideWith((ref) => Stream.value(const <MediaItem>[])),
      favoritesApiProvider.overrideWithValue(FakeFavoritesRepository()),
    ];
  }

  testWidgets('etat vide : message et commande de scan', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: baseOverrides(library: () => <Track>[]),
        child: const MaterialApp(home: LibraryScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Aucune piste dans la biblioth'),
      findsOneWidget,
    );
    expect(find.textContaining('FLAC et WAV'), findsOneWidget);
  });

  testWidgets('etat donnees : titre, artiste, format FLAC et specs', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: baseOverrides(library: () => <Track>[track]),
        child: const MaterialApp(home: LibraryScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Genesis'), findsOneWidget);
    expect(find.textContaining('Justice'), findsOneWidget);
    expect(find.textContaining('3:20'), findsOneWidget);
    expect(find.textContaining('44.1kHz'), findsOneWidget);
    expect(find.textContaining('FLAC'), findsOneWidget);
  });

  testWidgets('appui long ouvre un seul menu sans lancer la lecture', (
    tester,
  ) async {
    final playback = _FakePlaybackController();
    final handler = _QueueActionHandler();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...baseOverrides(library: () => <Track>[track]),
          libraryPlaybackControllerProvider.overrideWith((ref) => playback),
          audioHandlerProvider.overrideWithValue(handler),
        ],
        child: const MaterialApp(home: LibraryScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Genesis'));
    await tester.pumpAndSettle();

    expect(playback.calls, 0);
    expect(find.text('Lire ensuite'), findsOneWidget);
    expect(find.text('Ajouter à la file d’attente'), findsOneWidget);
    expect(find.text('Vitesse du titre'), findsOneWidget);
    final speedStub = tester.widget<ListTile>(
      find.descendant(
        of: find.byKey(const ValueKey('track-action-speed')),
        matching: find.byType(ListTile),
      ),
    );
    expect(speedStub.onTap, isNotNull);

    await tester.tap(find.byKey(const ValueKey('track-action-play-next')));
    await tester.pumpAndSettle();
    expect(handler.playNextIds, ['1']);
    expect(handler.playbackRateMutations, 0);
    expect(playback.calls, 0);
  });

  testWidgets('etat erreur : affiche le message serveur et retry', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        // Comme dans main.dart : pas de retry automatique Riverpod, l'erreur
        // doit être visible immédiatement avec son bouton « Réessayer ».
        retry: (retryCount, error) => null,
        overrides: [
          libraryProvider.overrideWith(
            (ref) => throw LibraryApiException('Serveur injoignable.'),
          ),
          mediaItemProvider.overrideWith(
            (ref) => const Stream<MediaItem?>.empty(),
          ),
          playbackStateProvider.overrideWith(
            (ref) => const Stream<PlaybackState>.empty(),
          ),
        ],
        child: const MaterialApp(home: LibraryScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Serveur injoignable.'), findsOneWidget);
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
  });

  testWidgets(
    'piste en cours : indicateur discret sans reconstruction globale',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            libraryProvider.overrideWith((ref) => Future.value(<Track>[track])),
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
          ],
          child: const MaterialApp(home: LibraryScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Genesis'), findsOneWidget);
      expect(find.textContaining('Justice'), findsOneWidget);
      expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);
      // Le mini-player persistant appartient désormais à HomeShell.
      expect(find.byIcon(Icons.pause_rounded), findsNothing);
    },
  );

  testWidgets(
    'bibliothèque dédiée : la file ne surcharge pas la barre supérieure',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            libraryProvider.overrideWith((ref) => Future.value(<Track>[track])),
            mediaItemProvider.overrideWith(
              (ref) => Stream.value(
                const MediaItem(id: '1', title: 'Genesis', artist: 'Justice'),
              ),
            ),
            playbackStateProvider.overrideWith(
              (ref) => Stream.value(
                PlaybackState(
                  playing: false,
                  processingState: AudioProcessingState.ready,
                  queueIndex: 0,
                ),
              ),
            ),
            queueProvider.overrideWith(
              (ref) => Stream.value(const <MediaItem>[
                MediaItem(id: '1', title: 'Genesis', artist: 'Justice'),
                MediaItem(id: '2', title: 'Stress', artist: 'Justice'),
              ]),
            ),
          ],
          child: const MaterialApp(home: LibraryScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.skip_next_rounded), findsNothing);
      expect(find.byIcon(Icons.search_rounded), findsOneWidget);
      expect(find.byIcon(Icons.sort_rounded), findsOneWidget);
    },
  );

  testWidgets('tap piste : lance la lecture sans ouvrir le lecteur complet', (
    tester,
  ) async {
    final controller = _FakePlaybackController();
    addTearDown(() {
      for (final completer in controller.pending) {
        if (!completer.isCompleted) completer.complete();
      }
    });
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, _) => const LibraryScreen()),
        GoRoute(
          path: '/player',
          builder: (_, _) => const Text('ecran lecteur'),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...baseOverrides(library: () => <Track>[track]),
          libraryPlaybackControllerProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Genesis'));
    await tester.pump();
    controller.pending[0].complete();
    await tester.pumpAndSettle();

    expect(controller.calls, 1);
    // La lecture est lancée mais on reste dans la bibliothèque.
    expect(find.text('ecran lecteur'), findsNothing);
    expect(find.text('Bibliothèque'), findsOneWidget);
  });

  testWidgets('barre supérieure limitée à la recherche et au tri', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: baseOverrides(library: () => <Track>[track]),
        child: const MaterialApp(home: LibraryScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.settings_rounded), findsNothing);
    expect(find.byIcon(Icons.search_rounded), findsOneWidget);
    expect(find.byIcon(Icons.sort_rounded), findsOneWidget);
  });

  testWidgets('aucun bouton Découvrir flottant ne recouvre les pistes', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: baseOverrides(library: () => <Track>[track]),
        child: const MaterialApp(home: LibraryScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.byIcon(Icons.explore_rounded), findsNothing);
  });

  testWidgets('tap piste : montre la preparation et evite le double tap', (
    tester,
  ) async {
    final completer = Completer<void>();
    final controller = _FakePlaybackController(completer);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...baseOverrides(library: () => <Track>[track]),
          libraryPlaybackControllerProvider.overrideWith((ref) => controller),
        ],
        child: const MaterialApp(home: LibraryScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Genesis'));
    await tester.pump();
    await tester.tap(find.text('Genesis'));
    await tester.pump();

    expect(controller.calls, 1);
    expect(controller.tracks, <Track>[track]);
    expect(controller.initialIndex, 0);
    expect(find.text('Préparation de la lecture…'), findsOneWidget);

    completer.complete();
    await tester.pumpAndSettle();

    expect(find.text('Préparation de la lecture…'), findsNothing);
  });

  testWidgets(
    'pendant une préparation, une autre piste reste cliquable et remplace',
    (tester) async {
      const stress = Track(
        id: 2,
        title: 'Stress',
        artist: 'Justice',
        album: 'Cross',
        hasCover: false,
        durationSeconds: 260,
        extension: '.flac',
        mimeType: 'audio/flac',
      );
      final controller = _FakePlaybackController();
      addTearDown(() {
        for (final completer in controller.pending) {
          if (!completer.isCompleted) completer.complete();
        }
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...baseOverrides(library: () => <Track>[track, stress]),
            libraryPlaybackControllerProvider.overrideWith((ref) => controller),
          ],
          child: const MaterialApp(home: LibraryScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Genesis'));
      await tester.pump();
      expect(controller.calls, 1);
      expect(find.text('Préparation de la lecture…'), findsOneWidget);

      // La liste n'est pas bloquée : une autre piste remplace la demande.
      await tester.tap(find.text('Stress'));
      await tester.pump();
      expect(controller.calls, 2);
      expect(controller.initialIndex, 1); // Stress, en ordre trié par titre.

      // L'ancienne préparation se termine : seule la nouvelle reste marquée.
      controller.pending[0].complete();
      await tester.pump();
      expect(find.text('Préparation de la lecture…'), findsOneWidget);

      controller.pending[1].complete();
      await tester.pumpAndSettle();
      expect(find.text('Préparation de la lecture…'), findsNothing);
    },
  );

  testWidgets('LibraryScreen : le tap prépare la file à l’index choisi', (
    tester,
  ) async {
    final completer = Completer<void>();
    final controller = _FakePlaybackController(completer);
    addTearDown(() {
      if (!completer.isCompleted) completer.complete();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...baseOverrides(library: () => <Track>[track]),
          libraryPlaybackControllerProvider.overrideWith((ref) => controller),
        ],
        child: const MaterialApp(home: LibraryScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Genesis'));
    await tester.pump();

    expect(controller.calls, 1);
    expect(controller.tracks, <Track>[track]);
    expect(controller.initialIndex, 0);
    expect(find.text('Préparation de la lecture…'), findsOneWidget);
  });
}

class _FakePlaybackController implements LibraryPlaybackController {
  _FakePlaybackController([this._fixedCompleter]);

  /// Completer unique (tests historiques) ; sinon un completer par appel.
  final Completer<void>? _fixedCompleter;
  final List<Completer<void>> pending = <Completer<void>>[];
  int calls = 0;
  List<Track>? tracks;
  int? initialIndex;

  @override
  Future<void> playQueue({
    required List<Track> tracks,
    required int initialIndex,
  }) {
    calls += 1;
    this.tracks = tracks;
    this.initialIndex = initialIndex;
    if (_fixedCompleter != null) return _fixedCompleter.future;
    final completer = Completer<void>();
    pending.add(completer);
    return completer.future;
  }
}

class _QueueActionHandler implements HomeSpotifyAudioHandler {
  final List<String> playNextIds = [];
  final List<String> queuedIds = [];
  int playbackRateMutations = 0;

  @override
  Future<void> playNext(PlayerQueueItem item) async => playNextIds.add(item.id);

  @override
  Future<void> addToQueue(PlayerQueueItem item) async => queuedIds.add(item.id);

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #setSpeed ||
        invocation.memberName == #setPlaybackRate) {
      playbackRateMutations += 1;
    }
    throw UnsupportedError('appel inattendu: ${invocation.memberName}');
  }
}
