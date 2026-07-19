import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:homespotify_mobile/src/features/library/data/library_api.dart';
import 'package:homespotify_mobile/src/features/library/data/playlists_api.dart';
import 'package:homespotify_mobile/src/features/library/domain/local_playlist.dart';
import 'package:homespotify_mobile/src/features/library/domain/track.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_favorites.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_playback_controller.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_playlists.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_screen.dart';
import 'package:homespotify_mobile/src/features/library/presentation/playlist_detail_screen.dart';
import 'package:homespotify_mobile/src/features/library/presentation/playlists_screen.dart';
import 'package:homespotify_mobile/src/features/player/presentation/player_providers.dart';

import 'support/fake_library_repositories.dart';

void main() {
  const genesis = Track(
    id: 1,
    title: 'Genesis',
    artist: 'Justice',
    album: 'Cross',
    hasCover: false,
    durationSeconds: 200,
  );
  const stress = Track(
    id: 2,
    title: 'Stress',
    artist: 'Justice',
    album: 'Cross',
    hasCover: false,
    durationSeconds: 260,
  );
  const aero = Track(
    id: 3,
    title: 'Aerodynamic',
    artist: 'Daft Punk',
    album: 'Discovery',
    hasCover: false,
  );
  const tracks = <Track>[genesis, stress, aero];

  Future<void> usePhoneSurface(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  GoRouter router({String initialLocation = '/'}) => GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(path: '/', builder: (_, _) => const LibraryScreen()),
      GoRoute(path: '/playlists', builder: (_, _) => const PlaylistsScreen()),
      GoRoute(
        path: '/playlists/:playlistId',
        builder: (_, state) => PlaylistDetailScreen(
          playlistId: state.pathParameters['playlistId'] ?? '',
        ),
      ),
      GoRoute(path: '/player', builder: (_, _) => const Text('écran lecteur')),
    ],
  );

  overrides({
    required PlaylistsRepository playlistsStore,
    _FakePlaybackController? controller,
    MediaItem? mediaItem,
  }) => [
    libraryProvider.overrideWith((ref) => Future.value(tracks)),
    favoritesApiProvider.overrideWithValue(FakeFavoritesRepository()),
    playlistsApiProvider.overrideWithValue(playlistsStore),
    mediaItemProvider.overrideWith(
      (ref) => mediaItem == null
          ? const Stream<MediaItem?>.empty()
          : Stream.value(mediaItem),
    ),
    playbackStateProvider.overrideWith(
      (ref) => mediaItem == null
          ? const Stream<PlaybackState>.empty()
          : Stream.value(
              PlaybackState(
                playing: true,
                processingState: AudioProcessingState.ready,
                queueIndex: 0,
              ),
            ),
    ),
    queueProvider.overrideWith(
      (ref) => Stream.value(
        mediaItem == null
            ? const <MediaItem>[]
            : const <MediaItem>[
                MediaItem(id: '1', title: 'Genesis', artist: 'Justice'),
                MediaItem(id: '2', title: 'Stress', artist: 'Justice'),
              ],
      ),
    ),
    if (controller != null)
      libraryPlaybackControllerProvider.overrideWith((ref) => controller),
  ];

  testWidgets('accès bibliothèque → Playlists et état vide propre', (
    tester,
  ) async {
    await usePhoneSurface(tester);
    final appRouter = router();
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(playlistsStore: FakePlaylistsRepository()),
        child: MaterialApp.router(
          theme: ThemeData.dark(),
          routerConfig: appRouter,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // La navigation de section est désormais une rangée horizontale de
    // ChoiceChips paresseuse : amener la puce dans le viewport avant le tap.
    final playlistsChip = find.widgetWithText(ChoiceChip, 'Playlists');
    await tester.scrollUntilVisible(
      playlistsChip,
      200,
      scrollable: find.descendant(
        of: find.byKey(
          const PageStorageKey<String>('library-section-navigation'),
        ),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(playlistsChip);
    await tester.pumpAndSettle();
    await tester.tap(playlistsChip);
    await tester.pumpAndSettle();

    expect(appRouter.state.uri.path, '/playlists');
    expect(find.text('Aucune playlist'), findsOneWidget);
    expect(find.byTooltip('Créer une playlist'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('annuler puis créer une playlist ne produit aucune erreur', (
    tester,
  ) async {
    await usePhoneSurface(tester);
    final appRouter = router(initialLocation: '/playlists');
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(playlistsStore: FakePlaylistsRepository()),
        child: MaterialApp.router(
          theme: ThemeData.dark(),
          routerConfig: appRouter,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Créer une playlist'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Annuler'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Créer une playlist'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Mix test');
    await tester.tap(find.text('Créer'));
    await tester.pumpAndSettle();

    expect(find.text('Mix test'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('suppression depuis le détail retourne à Playlists', (
    tester,
  ) async {
    await usePhoneSurface(tester);
    final store = FakePlaylistsRepository(const <LocalPlaylist>[
      LocalPlaylist(id: 'road', name: 'Route du soir', trackIds: <int>[1]),
    ]);
    final appRouter = router(initialLocation: '/playlists');
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(playlistsStore: store),
        child: MaterialApp.router(
          theme: ThemeData.dark(),
          routerConfig: appRouter,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Route du soir'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Supprimer la playlist'));
    await tester.pumpAndSettle();

    expect(find.text('Supprimer cette playlist ?'), findsOneWidget);
    await tester.tap(find.text('Supprimer'));
    await tester.pumpAndSettle();

    expect(appRouter.state.uri.path, '/playlists');
    expect(find.text('Aucune playlist'), findsOneWidget);
    expect(store.playlists, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tap piste joue la queue playlist au bon index sans /player', (
    tester,
  ) async {
    await usePhoneSurface(tester);
    final controller = _FakePlaybackController();
    addTearDown(controller.completeAll);
    final appRouter = router(initialLocation: '/playlists/road');
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(
          playlistsStore: FakePlaylistsRepository(const <LocalPlaylist>[
            LocalPlaylist(
              id: 'road',
              name: 'Route du soir',
              trackIds: <int>[1, 2],
            ),
          ]),
          controller: controller,
          mediaItem: const MediaItem(
            id: '1',
            title: 'Genesis',
            artist: 'Justice',
          ),
        ),
        child: MaterialApp.router(
          theme: ThemeData.dark(),
          routerConfig: appRouter,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Aerodynamic'), findsNothing);
    expect(find.text('Route du soir'), findsNWidgets(2));
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);

    await tester.tap(find.text('Stress'));
    await tester.pump();

    expect(controller.calls, 1);
    expect(controller.initialIndex, 1);
    expect(controller.tracks!.map((track) => track.title).toList(), [
      'Genesis',
      'Stress',
    ]);
    expect(find.text('écran lecteur'), findsNothing);

    controller.pending.single.complete();
    await tester.pumpAndSettle();
    expect(appRouter.state.uri.path, '/playlists/road');
  });

  testWidgets('l’indicateur suit la piste courante en lecture', (tester) async {
    await usePhoneSurface(tester);
    final mediaItems = StreamController<MediaItem?>();
    final playbackStates = StreamController<PlaybackState>();
    addTearDown(mediaItems.close);
    addTearDown(playbackStates.close);
    final appRouter = router(initialLocation: '/playlists/road');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          libraryProvider.overrideWith((ref) => Future.value(tracks)),
          favoritesApiProvider.overrideWithValue(FakeFavoritesRepository()),
          playlistsApiProvider.overrideWithValue(
            FakePlaylistsRepository(const <LocalPlaylist>[
              LocalPlaylist(
                id: 'road',
                name: 'Route du soir',
                trackIds: <int>[1, 2],
              ),
            ]),
          ),
          mediaItemProvider.overrideWith((ref) => mediaItems.stream),
          playbackStateProvider.overrideWith((ref) => playbackStates.stream),
          queueProvider.overrideWith(
            (ref) => Stream.value(const <MediaItem>[]),
          ),
        ],
        child: MaterialApp.router(
          theme: ThemeData.dark(),
          routerConfig: appRouter,
        ),
      ),
    );
    await tester.pumpAndSettle();

    mediaItems.add(
      const MediaItem(id: '1', title: 'Genesis', artist: 'Justice'),
    );
    await tester.pump();
    playbackStates.add(
      PlaybackState(playing: true, processingState: AudioProcessingState.ready),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('current-track-indicator-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('current-track-indicator-2')),
      findsNothing,
    );

    mediaItems.add(
      const MediaItem(id: '2', title: 'Stress', artist: 'Justice'),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('current-track-indicator-1')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('current-track-indicator-2')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

class _FakePlaybackController implements LibraryPlaybackController {
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
    final completer = Completer<void>();
    pending.add(completer);
    return completer.future;
  }

  void completeAll() {
    for (final completer in pending) {
      if (!completer.isCompleted) completer.complete();
    }
  }
}
