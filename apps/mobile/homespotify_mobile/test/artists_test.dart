import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:homespotify_mobile/src/app/navigation.dart';
import 'package:homespotify_mobile/src/features/library/data/library_api.dart';
import 'package:homespotify_mobile/src/features/library/domain/track.dart';
import 'package:homespotify_mobile/src/features/library/presentation/artist_detail_screen.dart';
import 'package:homespotify_mobile/src/features/library/presentation/artists_screen.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_artists.dart';
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
  const unknown = Track(
    id: 4,
    title: 'Mystery',
    artist: '',
    album: '',
    hasCover: false,
  );
  const tracks = <Track>[genesis, stress, aero, unknown];

  Future<void> usePhoneSurface(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  GoRouter buildRouter({String initialLocation = '/'}) => GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(path: '/', builder: (_, _) => const LibraryScreen()),
      GoRoute(path: '/artists', builder: (_, _) => const ArtistsScreen()),
      GoRoute(
        path: '/artists/:artistRouteId',
        builder: (_, state) => ArtistDetailScreen(
          artistKey:
              artistKeyFromRouteId(
                state.pathParameters['artistRouteId'] ?? '',
              ) ??
              '',
          focusAlbums: state.uri.queryParameters['section'] == 'albums',
        ),
      ),
      GoRoute(path: '/player', builder: (_, _) => const Text('écran lecteur')),
    ],
  );

  overrides({MediaItem? mediaItem, _FakePlaybackController? controller}) => [
    libraryProvider.overrideWith((ref) => Future.value(tracks)),
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

  testWidgets('navigation bibliothèque → artistes → détail → retour', (
    tester,
  ) async {
    await usePhoneSurface(tester);
    final router = buildRouter();
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(),
        child: MaterialApp.router(
          theme: ThemeData.dark(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.people_alt_outlined));
    await tester.pumpAndSettle();

    expect(find.text('Artistes'), findsOneWidget);
    expect(find.text('Daft Punk'), findsOneWidget);
    expect(find.text('Justice'), findsOneWidget);
    expect(find.text(unknownArtistTitle), findsOneWidget);

    await tester.tap(find.text('Justice'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Justice'), findsNWidgets(2));
    expect(find.text('Albums'), findsOneWidget);
    expect(
      find.byKey(ValueKey<String>('artist-album-${albumKeyForTitle('Cross')}')),
      findsOneWidget,
    );
    expect(find.text('Titres'), findsOneWidget);
    expect(find.text('Genesis'), findsOneWidget);
    expect(find.text('Stress'), findsOneWidget);
    expect(find.textContaining('2 pistes · 1 album'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Artistes'), findsOneWidget);
  });

  testWidgets('bouton Lire lance uniquement la queue artiste sans /player', (
    tester,
  ) async {
    await usePhoneSurface(tester);
    final controller = _FakePlaybackController();
    addTearDown(controller.completeAll);
    final router = buildRouter(
      initialLocation: artistDetailPath(artistKeyForName('Justice')),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(controller: controller),
        child: MaterialApp.router(
          theme: ThemeData.dark(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Lire'));
    await tester.pump();

    expect(controller.calls, 1);
    expect(controller.initialIndex, 0);
    expect(controller.tracks!.map((track) => track.title).toList(), [
      'Genesis',
      'Stress',
    ]);
    expect(find.text('écran lecteur'), findsNothing);

    controller.pending.single.complete();
    await tester.pumpAndSettle();
    expect(find.text('Lire'), findsOneWidget);
    expect(find.text('écran lecteur'), findsNothing);
  });

  testWidgets('tap piste lance la queue artiste au bon index sans /player', (
    tester,
  ) async {
    await usePhoneSurface(tester);
    final controller = _FakePlaybackController();
    addTearDown(controller.completeAll);
    final router = buildRouter(
      initialLocation: artistDetailPath(artistKeyForName('Justice')),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(controller: controller),
        child: MaterialApp.router(
          theme: ThemeData.dark(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Stress'));
    await tester.tap(find.text('Stress'));
    await tester.pump();

    expect(controller.calls, 1);
    expect(controller.initialIndex, 1);
    expect(controller.tracks, hasLength(2));
    expect(find.text('écran lecteur'), findsNothing);

    controller.pending.single.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('mini-player visible sur Artistes et détail Artiste', (
    tester,
  ) async {
    await usePhoneSurface(tester);
    final router = buildRouter(initialLocation: '/artists');
    const current = MediaItem(id: '1', title: 'Genesis', artist: 'Justice');
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(mediaItem: current),
        child: MaterialApp.router(
          theme: ThemeData.dark(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Genesis'), findsOneWidget);
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    expect(find.byIcon(Icons.skip_previous_rounded), findsOneWidget);
    expect(find.byIcon(Icons.skip_next_rounded), findsOneWidget);

    await tester.tap(find.text('Justice').first);
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    expect(find.byIcon(Icons.skip_previous_rounded), findsOneWidget);
    expect(find.byIcon(Icons.skip_next_rounded), findsOneWidget);
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
