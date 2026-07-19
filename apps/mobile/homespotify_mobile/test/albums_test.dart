import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:homespotify_mobile/src/app/navigation.dart';
import 'package:homespotify_mobile/src/features/library/data/library_api.dart';
import 'package:homespotify_mobile/src/features/library/domain/track.dart';
import 'package:homespotify_mobile/src/features/library/presentation/album_detail_screen.dart';
import 'package:homespotify_mobile/src/features/library/presentation/albums_screen.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_albums.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_playback_controller.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_screen.dart';
import 'package:homespotify_mobile/src/features/player/presentation/player_providers.dart';

void main() {
  const genesis = Track(
    id: 1,
    title: 'Genesis',
    artist: 'Justice',
    album: 'Cross',
    hasCover: false,
    durationSeconds: 200,
    extension: '.flac',
    mimeType: 'audio/flac',
  );
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
  const aero = Track(
    id: 3,
    title: 'Aerodynamic',
    artist: 'Daft Punk',
    album: 'Discovery',
    hasCover: false,
    durationSeconds: 212,
    extension: '.wav',
    mimeType: 'audio/wav',
  );
  const zulu = Track(
    id: 4,
    title: 'Zulu',
    artist: 'Inconnu',
    album: '',
    hasCover: false,
  );
  const all = <Track>[genesis, stress, aero, zulu];

  GoRouter buildRouter({String initialLocation = '/'}) => GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(path: '/', builder: (_, _) => const LibraryScreen()),
      GoRoute(path: '/albums', builder: (_, _) => const AlbumsScreen()),
      GoRoute(
        path: '/albums/:albumKey',
        builder: (_, state) => AlbumDetailScreen(
          albumKey:
              albumKeyFromRouteId(state.pathParameters['albumKey'] ?? '') ?? '',
        ),
      ),
      GoRoute(path: '/player', builder: (_, _) => const Text('ecran lecteur')),
    ],
  );

  overrides({MediaItem? mediaItem, _FakePlaybackController? controller}) => [
    libraryProvider.overrideWith((ref) => Future.value(all)),
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
    queueProvider.overrideWith((ref) => Stream.value(const <MediaItem>[])),
    if (controller != null)
      libraryPlaybackControllerProvider.overrideWith((ref) => controller),
  ];

  testWidgets('navigation : bibliothèque → albums → détail album', (
    tester,
  ) async {
    // Surface téléphone : les 3 albums de la grille (2 colonnes) sont bâtis.
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = buildRouter();
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    // Bibliothèque → Albums via le bouton de l'AppBar.
    await tester.tap(find.byIcon(Icons.album_outlined));
    await tester.pumpAndSettle();

    expect(find.text('Albums'), findsOneWidget);
    expect(find.text('Cross'), findsOneWidget);
    expect(find.text('Discovery'), findsOneWidget);
    expect(find.text('Album inconnu'), findsOneWidget);
    expect(find.textContaining('2 pistes'), findsOneWidget);

    // Albums → détail.
    await tester.tap(find.text('Cross'));
    await tester.pumpAndSettle();

    // Titre dans l'AppBar + dans l'entête.
    expect(find.text('Cross'), findsNWidgets(2));
    expect(find.text('Lire'), findsOneWidget);
    expect(find.text('Genesis'), findsOneWidget);
    expect(find.text('Stress'), findsOneWidget);
    expect(find.textContaining('2 pistes'), findsOneWidget);
  });

  testWidgets('bouton Lire : lance la file de l’album sans ouvrir /player', (
    tester,
  ) async {
    final controller = _FakePlaybackController();
    addTearDown(() {
      for (final completer in controller.pending) {
        if (!completer.isCompleted) completer.complete();
      }
    });
    final router = buildRouter(initialLocation: albumDetailPath('a:cross'));
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(controller: controller),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Lire'));
    await tester.pump();

    expect(controller.calls, 1);
    expect(controller.initialIndex, 0);
    expect(controller.tracks!.map((t) => t.title).toList(), [
      'Genesis',
      'Stress',
    ]);
    expect(find.text('ecran lecteur'), findsNothing);

    controller.pending[0].complete();
    await tester.pumpAndSettle();

    // Toujours sur le détail album, pas de lecteur complet.
    expect(find.text('Lire'), findsOneWidget);
    expect(find.text('ecran lecteur'), findsNothing);
  });

  testWidgets('tap piste album : lance la file au bon index, sans /player', (
    tester,
  ) async {
    final controller = _FakePlaybackController();
    addTearDown(() {
      for (final completer in controller.pending) {
        if (!completer.isCompleted) completer.complete();
      }
    });
    final router = buildRouter(initialLocation: albumDetailPath('a:cross'));
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(controller: controller),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Stress'));
    await tester.pump();

    expect(controller.calls, 1);
    expect(controller.initialIndex, 1);
    expect(controller.tracks, hasLength(2));

    controller.pending[0].complete();
    await tester.pumpAndSettle();
    expect(find.text('ecran lecteur'), findsNothing);
  });

  testWidgets('mini-player visible sur l’écran Albums', (tester) async {
    final router = buildRouter(initialLocation: '/albums');
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(
          mediaItem: const MediaItem(
            id: '1',
            title: 'Genesis',
            artist: 'Justice',
          ),
        ),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    // Mini-player : titre en cours + pause + précédent/suivant.
    expect(find.text('Genesis'), findsOneWidget);
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    expect(find.byIcon(Icons.skip_previous_rounded), findsOneWidget);
    expect(find.byIcon(Icons.skip_next_rounded), findsOneWidget);
  });

  testWidgets('mini-player visible sur le détail album', (tester) async {
    final router = buildRouter(initialLocation: albumDetailPath('a:cross'));
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(
          mediaItem: const MediaItem(
            id: '1',
            title: 'Genesis',
            artist: 'Justice',
          ),
        ),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    expect(find.byIcon(Icons.skip_previous_rounded), findsOneWidget);
    expect(find.byIcon(Icons.skip_next_rounded), findsOneWidget);
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
}
