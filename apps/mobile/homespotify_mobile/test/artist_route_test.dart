import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:homespotify_mobile/src/app/navigation.dart';
import 'package:homespotify_mobile/src/features/library/data/library_api.dart';
import 'package:homespotify_mobile/src/features/library/presentation/artist_detail_screen.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_artists.dart';
import 'package:homespotify_mobile/src/features/player/presentation/player_providers.dart';

const dangerousArtists = <String>[
  "Guns N' Roses",
  'Artist 100%',
  'AC/DC',
  'Émilie Simon',
  'A+B & C ★',
];

void main() {
  group('routeId artiste URL-safe', () {
    test('aller-retour sans perte pour les caractères spéciaux', () {
      for (final name in dangerousArtists) {
        final key = artistKeyForName(name);
        final routeId = artistRouteId(key);
        expect(RegExp(r'^[A-Za-z0-9\-_=]+$').hasMatch(routeId), isTrue);
        expect(artistKeyFromRouteId(routeId), key);

        final path = artistDetailPath(key);
        expect(path.contains('%'), isFalse, reason: 'path=$path');
        expect(Uri.parse(path).path, path);
      }
    });

    test('identifiant invalide retourne null sans exception', () {
      expect(artistKeyFromRouteId('!!!pas-du-base64!!!'), isNull);
      expect(artistKeyFromRouteId('%zz'), isNull);
      expect(artistKeyFromRouteId(''), '');
    });
  });

  testWidgets('route artiste invalide affiche une UI sombre et un retour', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/artists/!!!pas-du-base64!!!',
      routes: [
        GoRoute(
          path: '/artists',
          builder: (_, _) => const Scaffold(body: Text('écran artistes')),
        ),
        GoRoute(
          path: '/artists/:artistRouteId',
          builder: (_, state) => ArtistDetailScreen(
            artistKey:
                artistKeyFromRouteId(
                  state.pathParameters['artistRouteId'] ?? '',
                ) ??
                '',
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          libraryProvider.overrideWith((ref) => Future.value(const [])),
          mediaItemProvider.overrideWith(
            (ref) => const Stream<MediaItem?>.empty(),
          ),
          playbackStateProvider.overrideWith(
            (ref) => const Stream<PlaybackState>.empty(),
          ),
          queueProvider.overrideWith(
            (ref) => Stream.value(const <MediaItem>[]),
          ),
        ],
        child: MaterialApp.router(
          theme: ThemeData.dark(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Artiste introuvable'), findsOneWidget);
    expect(find.text('Retour'), findsOneWidget);
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      const Color(0xFF0D0D10),
    );
  });
}
