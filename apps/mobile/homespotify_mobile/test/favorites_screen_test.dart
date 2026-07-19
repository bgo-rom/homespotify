import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:homespotify_mobile/src/features/library/data/favorites_api.dart';
import 'package:homespotify_mobile/src/features/library/data/library_api.dart';
import 'package:homespotify_mobile/src/features/library/domain/track.dart';
import 'package:homespotify_mobile/src/features/library/presentation/favorites_screen.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_favorites.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_playback_controller.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_screen.dart';
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
    durationSeconds: 212,
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
      GoRoute(path: '/favorites', builder: (_, _) => const FavoritesScreen()),
      GoRoute(path: '/player', builder: (_, _) => const Text('écran lecteur')),
    ],
  );

  overrides({
    required FavoritesRepository store,
    _FakePlaybackController? controller,
    MediaItem? mediaItem,
  }) => [
    libraryProvider.overrideWith((ref) => Future.value(tracks)),
    favoritesApiProvider.overrideWithValue(store),
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

  testWidgets('accès bibliothèque → Favoris et état vide propre', (
    tester,
  ) async {
    await usePhoneSurface(tester);
    final appRouter = router();
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(store: FakeFavoritesRepository(<int>{})),
        child: MaterialApp.router(
          theme: ThemeData.dark(),
          routerConfig: appRouter,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // La navigation de section est désormais une rangée horizontale de
    // ChoiceChips paresseuse : amener la puce dans le viewport avant le tap.
    final favorisChip = find.widgetWithText(ChoiceChip, 'Favoris');
    await tester.scrollUntilVisible(
      favorisChip,
      200,
      scrollable: find.descendant(
        of: find.byKey(
          const PageStorageKey<String>('library-section-navigation'),
        ),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(favorisChip);
    await tester.pumpAndSettle();
    await tester.tap(favorisChip);
    await tester.pumpAndSettle();

    expect(appRouter.state.uri.path, '/favorites');
    expect(find.text('Favoris'), findsOneWidget);
    expect(find.text('Aucun favori'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tap piste joue la queue Favoris sans ouvrir le lecteur', (
    tester,
  ) async {
    await usePhoneSurface(tester);
    final controller = _FakePlaybackController();
    addTearDown(controller.completeAll);
    final appRouter = router(initialLocation: '/favorites');
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(
          store: FakeFavoritesRepository(<int>{1, 2}),
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
    expect(appRouter.state.uri.path, '/favorites');
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
