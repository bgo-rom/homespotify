import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:homespotify_mobile/src/features/library/data/library_api.dart';
import 'package:homespotify_mobile/src/features/library/domain/track.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_favorites.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_screen.dart';
import 'package:homespotify_mobile/src/features/player/audio/homespotify_audio_handler.dart';
import 'package:homespotify_mobile/src/features/player/presentation/player_providers.dart';
import 'package:homespotify_mobile/src/features/player/presentation/widgets/mini_player.dart';

import 'support/fake_library_repositories.dart';

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
  const aero = Track(
    id: 2,
    title: 'Aerodynamic',
    artist: 'Daft Punk',
    album: 'Discovery',
    hasCover: false,
    durationSeconds: 212,
    extension: '.wav',
    mimeType: 'audio/wav',
  );
  const breathe = Track(
    id: 3,
    title: 'Breathe',
    artist: 'Pink Floyd',
    album: 'The Dark Side of the Moon',
    hasCover: false,
    durationSeconds: 169,
    extension: '.flac',
    mimeType: 'audio/flac',
  );
  const all = <Track>[genesis, aero, breathe];

  overrides({MediaItem? mediaItem}) => [
    libraryProvider.overrideWith((ref) => Future.value(all)),
    // Aucune requête réseau réelle : le HttpClient de flutter_test répond 400
    // à tout, ce qui polluerait les logs et laisserait des timers Dio.
    favoritesApiProvider.overrideWithValue(FakeFavoritesRepository()),
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
              ),
            ),
    ),
    queueProvider.overrideWith((ref) => Stream.value(const <MediaItem>[])),
    positionDataProvider.overrideWith(
      (ref) => Stream.value(PlayerPositionData.zero),
    ),
  ];

  Future<void> pumpLibrary(
    WidgetTester tester, {
    MediaItem? mediaItem,
    bool withMiniPlayer = false,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(mediaItem: mediaItem),
        child: MaterialApp(
          // Le mini-player vit dans HomeShell (au-dessus de la barre de
          // navigation), pas dans LibraryScreen : le harnais reproduit la
          // même structure Scaffold body + bottomNavigationBar.
          home: withMiniPlayer
              ? const Scaffold(
                  body: LibraryScreen(),
                  bottomNavigationBar: MiniPlayer(safeAreaBottom: false),
                )
              : const LibraryScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  // La recherche est repliée par défaut : le champ n'existe qu'après un tap
  // sur le bouton de recherche de l'AppBar.
  Future<void> openSearch(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('library-search-button')));
    await tester.pumpAndSettle();
  }

  Future<void> search(WidgetTester tester, String query) async {
    await openSearch(tester);
    await tester.enterText(
      find.byKey(const ValueKey('library-search-field')),
      query,
    );
    await tester.pumpAndSettle();
  }

  double dyOf(WidgetTester tester, String title) =>
      tester.getTopLeft(find.text(title)).dy;

  testWidgets('recherche par titre : seul le titre correspondant reste', (
    tester,
  ) async {
    await pumpLibrary(tester);

    await search(tester, 'gene');

    expect(find.text('Genesis'), findsOneWidget);
    expect(find.text('Aerodynamic'), findsNothing);
    expect(find.text('Breathe'), findsNothing);
  });

  testWidgets('recherche par artiste', (tester) async {
    await pumpLibrary(tester);

    await search(tester, 'daft');

    expect(find.text('Aerodynamic'), findsOneWidget);
    expect(find.text('Genesis'), findsNothing);
    expect(find.text('Breathe'), findsNothing);
  });

  testWidgets('recherche par album', (tester) async {
    await pumpLibrary(tester);

    await search(tester, 'dark side');

    expect(find.text('Breathe'), findsOneWidget);
    expect(find.text('Genesis'), findsNothing);
    expect(find.text('Aerodynamic'), findsNothing);
  });

  testWidgets('recherche sans résultat : message clair + effacement', (
    tester,
  ) async {
    await pumpLibrary(tester);

    await search(tester, 'zzzz');

    expect(find.textContaining('Aucun résultat pour'), findsOneWidget);
    expect(find.textContaining('zzzz'), findsWidgets);

    // Le bouton de l'AppBar (devenu « Fermer la recherche ») efface la
    // requête et restaure la liste complète.
    await tester.tap(find.byKey(const ValueKey('library-search-button')));
    await tester.pumpAndSettle();
    expect(find.text('Genesis'), findsOneWidget);
    expect(find.text('Aerodynamic'), findsOneWidget);
    expect(find.text('Breathe'), findsOneWidget);
  });

  testWidgets('tri par défaut : titre A → Z', (tester) async {
    await pumpLibrary(tester);

    expect(dyOf(tester, 'Aerodynamic'), lessThan(dyOf(tester, 'Breathe')));
    expect(dyOf(tester, 'Breathe'), lessThan(dyOf(tester, 'Genesis')));
  });

  testWidgets('tri par artiste via le menu', (tester) async {
    await pumpLibrary(tester);

    await tester.tap(find.byIcon(Icons.sort_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Artiste (A → Z)'));
    await tester.pumpAndSettle();

    // Daft Punk < Justice < Pink Floyd.
    expect(dyOf(tester, 'Aerodynamic'), lessThan(dyOf(tester, 'Genesis')));
    expect(dyOf(tester, 'Genesis'), lessThan(dyOf(tester, 'Breathe')));
  });

  testWidgets('tri par album via le menu', (tester) async {
    await pumpLibrary(tester);

    await tester.tap(find.byIcon(Icons.sort_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Album (A → Z)'));
    await tester.pumpAndSettle();

    // Cross < Discovery < The Dark Side of the Moon.
    expect(dyOf(tester, 'Genesis'), lessThan(dyOf(tester, 'Aerodynamic')));
    expect(dyOf(tester, 'Aerodynamic'), lessThan(dyOf(tester, 'Breathe')));
  });

  testWidgets('mini-player toujours visible pendant une recherche', (
    tester,
  ) async {
    await pumpLibrary(
      tester,
      mediaItem: const MediaItem(id: '1', title: 'Genesis', artist: 'Justice'),
      withMiniPlayer: true,
    );

    await search(tester, 'daft');

    // Liste filtrée sur Aerodynamic, mais le mini-player affiche toujours
    // la piste en cours (Genesis) avec son bouton pause.
    expect(find.text('Aerodynamic'), findsOneWidget);
    expect(find.text('Genesis'), findsOneWidget);
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    expect(find.byIcon(Icons.skip_next_rounded), findsOneWidget);
  });
}
