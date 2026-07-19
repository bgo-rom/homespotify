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
import 'package:homespotify_mobile/src/features/player/presentation/player_providers.dart';

/// Noms d'albums « dangereux » pour une URI : apostrophe, pourcentage, slash,
/// accents, plus et esperluette. Aucun ne doit provoquer de crash.
const dangerousAlbums = <String>[
  "Upstairs at Eric's",
  'Album 100% Hits',
  'Rock/Pop',
  'Été 2026',
  'A+B & C',
];

void main() {
  group('albumRouteId / albumKeyFromRouteId', () {
    test('aller-retour sans perte pour tous les noms dangereux', () {
      for (final name in dangerousAlbums) {
        final key = albumKeyForTitle(name);
        final routeId = albumRouteId(key);
        // L'identifiant est URL-safe : aucun caractère réservé d'URI.
        expect(RegExp(r'^[A-Za-z0-9\-_=]+$').hasMatch(routeId), isTrue);
        expect(albumKeyFromRouteId(routeId), key);
      }
    });

    test('identifiant illisible : null, jamais d’exception', () {
      expect(albumKeyFromRouteId('!!!pas-du-base64!!!'), isNull);
      expect(albumKeyFromRouteId('%zz'), isNull);
      // Vide : clé vide, qui ne matche aucun album (UI « introuvable »).
      expect(albumKeyFromRouteId(''), '');
    });
  });

  group('navigation détail album avec caractères spéciaux', () {
    GoRouter buildRouter() => GoRouter(
      initialLocation: '/albums',
      routes: [
        GoRoute(path: '/albums', builder: (_, _) => const AlbumsScreen()),
        GoRoute(
          path: '/albums/:albumKey',
          builder: (_, state) => AlbumDetailScreen(
            albumKey:
                albumKeyFromRouteId(state.pathParameters['albumKey'] ?? '') ??
                '',
          ),
        ),
      ],
    );

    overridesFor(List<Track> tracks) => [
      libraryProvider.overrideWith((ref) => Future.value(tracks)),
      mediaItemProvider.overrideWith((ref) => const Stream<MediaItem?>.empty()),
      playbackStateProvider.overrideWith(
        (ref) => const Stream<PlaybackState>.empty(),
      ),
      queueProvider.overrideWith((ref) => Stream.value(const <MediaItem>[])),
    ];

    for (final name in dangerousAlbums) {
      testWidgets('tap album « $name » ouvre le détail sans crash', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(const Size(400, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final track = Track(
          id: 1,
          title: 'Piste test',
          artist: 'Artiste test',
          album: name,
          hasCover: false,
          durationSeconds: 200,
          extension: '.flac',
          mimeType: 'audio/flac',
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: overridesFor([track]),
            child: MaterialApp.router(routerConfig: buildRouter()),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text(name));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        // Détail ouvert : titre (AppBar + entête) et bouton Lire.
        expect(find.text(name), findsNWidgets(2));
        expect(find.text('Lire'), findsOneWidget);
        expect(find.text('Piste test'), findsOneWidget);
      });
    }

    testWidgets('route album invalide : UI propre + bouton Retour', (
      tester,
    ) async {
      final router = GoRouter(
        initialLocation: '/albums/!!!pas-du-base64!!!',
        routes: [
          GoRoute(
            path: '/albums',
            builder: (_, _) => const Scaffold(body: Text('ecran albums')),
          ),
          GoRoute(
            path: '/albums/:albumKey',
            builder: (_, state) => AlbumDetailScreen(
              albumKey:
                  albumKeyFromRouteId(state.pathParameters['albumKey'] ?? '') ??
                  '',
            ),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: overridesFor(const []),
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('Album introuvable'), findsOneWidget);
      expect(find.text('Retour'), findsOneWidget);
    });
  });

  test('albumDetailPath ne contient jamais de percent-encoding', () {
    for (final name in dangerousAlbums) {
      final path = albumDetailPath(albumKeyForTitle(name));
      expect(path.contains('%'), isFalse, reason: 'path=$path');
      expect(Uri.parse(path).path, path);
    }
  });
}
