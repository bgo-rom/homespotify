import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:homespotify_mobile/src/app/home_shell.dart';
import 'package:homespotify_mobile/src/features/auth/application/auth_controller.dart';
import 'package:homespotify_mobile/src/features/catalog/data/catalog_api.dart';
import 'package:homespotify_mobile/src/features/home/presentation/home_dashboard_screen.dart';
import 'package:homespotify_mobile/src/features/library/data/library_api.dart';
import 'package:homespotify_mobile/src/features/library/domain/track.dart';
import 'package:homespotify_mobile/src/features/player/presentation/player_providers.dart';

import 'support/fake_auth.dart';

void main() {
  testWidgets('navigation principale expose quatre destinations explicites', (
    tester,
  ) async {
    var selected = -1;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: HomeBottomNavigation(
            selectedIndex: 0,
            onDestinationSelected: (index) => selected = index,
          ),
        ),
      ),
    );

    expect(find.text('Accueil'), findsOneWidget);
    expect(find.text('Bibliothèque'), findsOneWidget);
    expect(find.text('Découvrir'), findsOneWidget);
    expect(find.text('Profil'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('destination-library')));
    expect(selected, 1);
  });

  testWidgets('accueil présente les sections déjà alimentées localement', (
    tester,
  ) async {
    const tracks = <Track>[
      Track(
        id: 2,
        title: 'Freakin’ Out',
        artist: 'The Wrecks',
        album: 'Infinitely Ordinary',
        hasCover: false,
        durationSeconds: 185,
        extension: '.flac',
      ),
      Track(
        id: 1,
        title: 'Genesis',
        artist: 'Justice',
        album: 'Cross',
        hasCover: false,
        durationSeconds: 200,
        extension: '.flac',
      ),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...authOverrides(
            state: AuthState(
              AuthStatus.authenticated,
              user: makeUser(username: 'Camille'),
            ),
          ),
          libraryProvider.overrideWith((ref) => Future.value(tracks)),
          // « Ajouts récents » est alimentée par le catalogue global, plus
          // par la bibliothèque du compte.
          catalogRecentProvider.overrideWith(
            (ref) async => [
              for (final track in tracks)
                CatalogEntry(track: track, inMyLibrary: true),
            ],
          ),
          mediaItemProvider.overrideWith(
            (ref) => const Stream<MediaItem?>.empty(),
          ),
          playbackStateProvider.overrideWith(
            (ref) => const Stream<PlaybackState>.empty(),
          ),
        ],
        child: const MaterialApp(home: HomeDashboardScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Camille'), findsOneWidget);
    expect(find.text('Accès rapides'), findsOneWidget);
    expect(find.text('Ajouts récents'), findsOneWidget);
    // « Favoris » et « Playlists » apparaissent maintenant deux fois : dans les
    // accès rapides ET comme titres de carrousel.
    expect(find.text('Favoris'), findsWidgets);
    expect(find.text('Playlists'), findsWidgets);
    // Un même titre peut légitimement figurer dans plusieurs sections
    // (catalogue récent, récemment ajoutés, favoris…).
    expect(find.text('Freakin’ Out'), findsWidgets);

    // Sections de la refonte, alimentées par la bibliothèque locale.
    expect(find.byKey(const ValueKey('home-shuffle-library')), findsOneWidget);
    expect(find.byKey(const ValueKey('home-recently-added')), findsOneWidget);
    expect(find.byKey(const ValueKey('home-recommendations')), findsOneWidget);
    // Rien à installer : la section reste absente, pas vide.
    expect(find.byKey(const ValueKey('home-installations')), findsNothing);
  });
}
