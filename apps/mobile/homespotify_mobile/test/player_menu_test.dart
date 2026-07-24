import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:homespotify_mobile/src/app/navigation.dart';
import 'package:homespotify_mobile/src/features/library/data/library_api.dart';
import 'package:homespotify_mobile/src/features/library/domain/local_playlist.dart';
import 'package:homespotify_mobile/src/features/library/domain/track.dart';
import 'package:homespotify_mobile/src/features/library/presentation/album_detail_screen.dart';
import 'package:homespotify_mobile/src/features/library/presentation/artist_detail_screen.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_albums.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_artists.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_favorites.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_playlists.dart';
import 'package:homespotify_mobile/src/features/player/audio/homespotify_audio_handler.dart';
import 'package:homespotify_mobile/src/features/player/presentation/player_providers.dart';
import 'package:homespotify_mobile/src/features/player/presentation/player_screen.dart';

import 'support/fake_library_repositories.dart';

void main() {
  late _MenuAudioHandler menuAudioHandler;
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

  Future<void> usePhoneSurface(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  overrides({
    required _MenuAudioHandler audioHandler,
    String artist = 'Justice',
    Map<String, dynamic>? extras,
  }) => [
    audioHandlerProvider.overrideWithValue(audioHandler),
    libraryProvider.overrideWith((ref) => Future.value(const [genesis])),
    favoritesApiProvider.overrideWithValue(FakeFavoritesRepository()),
    playlistsApiProvider.overrideWithValue(
      FakePlaylistsRepository(const <LocalPlaylist>[
        LocalPlaylist(id: 'road', name: 'Route du soir', trackIds: <int>[]),
      ]),
    ),
    mediaItemProvider.overrideWith(
      (ref) => Stream.value(
        MediaItem(
          id: '1',
          title: 'Genesis',
          artist: artist,
          album: 'Cross',
          duration: const Duration(minutes: 3, seconds: 20),
          extras: extras,
        ),
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

  GoRouter buildRouter() => GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const Scaffold(body: Text('bibliotheque')),
      ),
      GoRoute(
        path: '/albums/:albumKey',
        builder: (_, state) => AlbumDetailScreen(
          albumKey:
              albumKeyFromRouteId(state.pathParameters['albumKey'] ?? '') ?? '',
        ),
      ),
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
      GoRoute(path: '/player', builder: (_, _) => const PlayerScreen()),
    ],
  );

  Future<GoRouter> pumpPlayer(
    WidgetTester tester, {
    String artist = 'Justice',
    Map<String, dynamic>? extras,
  }) async {
    await usePhoneSurface(tester);
    menuAudioHandler = _MenuAudioHandler();
    addTearDown(menuAudioHandler.dispose);
    final router = buildRouter();
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(
          audioHandler: menuAudioHandler,
          artist: artist,
          extras: extras,
        ),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    router.push('/player');
    await tester.pumpAndSettle();
    return router;
  }

  testWidgets('menu 3 points visible et items affichés', (tester) async {
    await pumpPlayer(tester);

    expect(find.byIcon(Icons.more_vert_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Voir la page de l’artiste'), findsOneWidget);
    expect(find.text('Voir les albums de l’artiste'), findsOneWidget);
    expect(find.text('Voir l’album de cette piste'), findsOneWidget);
    expect(find.text('Ajouter aux favoris'), findsOneWidget);
    expect(find.text('Ajouter à une playlist'), findsOneWidget);
    expect(find.text('Détails du fichier'), findsOneWidget);
    expect(find.text('Minuteur de sommeil'), findsOneWidget);
    expect(find.text('Partager'), findsOneWidget);
  });

  testWidgets('le minuteur est armé puis annulé depuis le lecteur', (
    tester,
  ) async {
    await pumpPlayer(tester);

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Minuteur de sommeil'));
    await tester.pumpAndSettle();

    expect(find.text('15 min'), findsOneWidget);
    expect(find.text('À la fin du titre'), findsOneWidget);
    await tester.tap(find.text('15 min'));
    await tester.pumpAndSettle();
    expect(menuAudioHandler.sleepTimerState.mode, SleepTimerMode.timed);

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Minuteur de sommeil'));
    await tester.pumpAndSettle();
    expect(find.text('Annuler le minuteur'), findsOneWidget);
    await tester.tap(find.text('Annuler le minuteur'));
    await tester.pumpAndSettle();
    expect(menuAudioHandler.sleepTimerState.mode, SleepTimerMode.off);
  });

  testWidgets('Détails du fichier affiche les métadonnées puis se ferme', (
    tester,
  ) async {
    await pumpPlayer(
      tester,
      extras: const <String, dynamic>{
        'format': 'FLAC',
        'sampleRate': 96000,
        'bitDepth': 24,
        'channels': 2,
        'bitrate': 2304000,
        'fileSize': 52428800,
      },
    );

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Détails du fichier'));
    await tester.pumpAndSettle();

    expect(find.text('96 kHz'), findsOneWidget);
    expect(find.text('24 bits'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('file-detail-Nombre de canaux')),
        matching: find.text('2'),
      ),
      findsOneWidget,
    );
    expect(find.text('2304 kb/s'), findsOneWidget);
    expect(find.text('50.0 Mo'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('file-detail-ID de la piste')),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('file-detail-ID de la piste')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Fermer'));
    await tester.pumpAndSettle();

    expect(find.text('Détails du fichier'), findsNothing);
    expect(find.text('EN LECTURE'), findsOneWidget);
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
  });

  testWidgets('Détails partiels affiche Inconnu sans erreur', (tester) async {
    await pumpPlayer(tester);

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Détails du fichier'));
    await tester.pumpAndSettle();

    expect(find.text('Inconnu'), findsNWidgets(6));
    expect(find.text('Fermer'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    '« Voir l’album de cette piste » ouvre le détail (remplace /player)',
    (tester) async {
      final router = await pumpPlayer(tester);

      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Voir l’album de cette piste'));
      await tester.pumpAndSettle();

      // Détail de l'album Cross ouvert, lecteur remplacé (pas d'empilement).
      expect(find.text('Lire'), findsOneWidget);
      expect(find.text('EN LECTURE'), findsNothing);
      expect(router.state.uri.path, albumDetailPath(albumKeyForTitle('Cross')));

      // Un seul retour ramène à l'écran d'origine.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('bibliotheque'), findsOneWidget);
    },
  );

  testWidgets('Voir la page artiste ouvre le détail et remplace /player', (
    tester,
  ) async {
    final router = await pumpPlayer(tester);

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Voir la page de l’artiste'));
    await tester.pumpAndSettle();

    expect(find.text('Titres'), findsOneWidget);
    expect(find.text('EN LECTURE'), findsNothing);
    expect(
      router.state.uri.path,
      artistDetailPath(artistKeyForName('Justice')),
    );
    // La lecture continue via le mini-player du détail artiste.
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
  });

  testWidgets('Voir les albums artiste ouvre la section pertinente', (
    tester,
  ) async {
    final router = await pumpPlayer(tester);

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Voir les albums de l’artiste'));
    await tester.pumpAndSettle();

    expect(find.text('Albums'), findsOneWidget);
    expect(
      find.byKey(ValueKey<String>('artist-album-${albumKeyForTitle('Cross')}')),
      findsOneWidget,
    );
    expect(router.state.uri.queryParameters['section'], 'albums');
    expect(find.text('EN LECTURE'), findsNothing);
  });

  testWidgets('artiste inconnu : SnackBar propre et lecteur conservé', (
    tester,
  ) async {
    await pumpPlayer(tester, artist: 'Artiste inconnu');

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Voir la page de l’artiste'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.textContaining('Artiste inconnu'),
      ),
      findsOneWidget,
    );
    expect(find.text('EN LECTURE'), findsOneWidget);
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
  });

  testWidgets('menu favori : ajoute puis propose le retrait', (tester) async {
    await pumpPlayer(tester);

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ajouter aux favoris'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Retirer des favoris'), findsOneWidget);
    expect(find.text('EN LECTURE'), findsOneWidget);
  });

  testWidgets('la sélection playlist reste ouverte et bascule ajout/retrait', (
    tester,
  ) async {
    await pumpPlayer(tester);

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ajouter à une playlist'));
    await tester.pumpAndSettle();

    expect(find.text('Route du soir'), findsOneWidget);
    await tester.tap(find.text('Route du soir'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Piste ajoutée'), findsOneWidget);
    expect(find.text('Ajouter à une playlist'), findsOneWidget);
    expect(find.byKey(const ValueKey('playlist-selected')), findsOneWidget);

    await tester.tap(find.text('Route du soir'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Piste retirée'), findsOneWidget);
    expect(find.text('Ajouter à une playlist'), findsOneWidget);
    expect(find.byKey(const ValueKey('playlist-unselected')), findsOneWidget);
    expect(find.text('EN LECTURE'), findsOneWidget);
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
  });
}

class _MenuAudioHandler implements HomeSpotifyAudioHandler {
  final ValueNotifier<SleepTimerState> _sleepTimer =
      ValueNotifier<SleepTimerState>(const SleepTimerState.off());

  @override
  ValueListenable<SleepTimerState> get sleepTimerListenable => _sleepTimer;

  @override
  SleepTimerState get sleepTimerState => _sleepTimer.value;

  @override
  void armSleepTimer(Duration duration) {
    _sleepTimer.value = SleepTimerState(
      mode: SleepTimerMode.timed,
      endsAt: DateTime.now().add(duration),
    );
  }

  @override
  void armSleepTimerAtEndOfTrack() {
    _sleepTimer.value = const SleepTimerState(
      mode: SleepTimerMode.endOfTrack,
      armedTrackId: '1',
    );
  }

  @override
  void cancelSleepTimer({String reason = 'user'}) {
    _sleepTimer.value = const SleepTimerState.off();
  }

  @override
  Future<void> dispose() async {
    _sleepTimer.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}
