@Tags(['capture'])
library;

import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:homespotify_mobile/src/core/theme/app_theme.dart';
import 'package:homespotify_mobile/src/features/auth/application/auth_controller.dart';
import 'package:homespotify_mobile/src/features/catalog/data/catalog_api.dart';
import 'package:homespotify_mobile/src/features/home/presentation/home_dashboard_screen.dart';
import 'package:homespotify_mobile/src/features/library/data/library_api.dart';
import 'package:homespotify_mobile/src/features/library/domain/track.dart';
import 'package:homespotify_mobile/src/features/player/audio/homespotify_audio_handler.dart';
import 'package:homespotify_mobile/src/features/player/presentation/player_providers.dart';

import 'support/fake_auth.dart';

/// Rendu de référence de l'Accueil « Direction 33 » en clair ET en sombre.
///
/// Double rôle :
/// 1. vérifier que le MÊME arbre de widgets tient dans les deux thèmes, sans
///    débordement ni exception ;
/// 2. produire `test/goldens/accueil-{light,dark}.png`, qui servent à la fois
///    de comparaison visuelle avec les planches de référence et de garde-fou
///    de non-régression.
///
/// Régénérer après un changement de design assumé :
/// `flutter test test/home_direction33_capture_test.dart --update-goldens`.
void main() {
  const tracks = <Track>[
    Track(
      id: 1,
      title: 'Lofi Home',
      artist: 'Nuit Douce',
      album: 'Maison',
      hasCover: false,
      durationSeconds: 214,
      extension: '.flac',
    ),
    Track(
      id: 2,
      title: 'Café Crème',
      artist: 'Petit Biscuit',
      album: 'Matin',
      hasCover: false,
      durationSeconds: 187,
      extension: '.flac',
    ),
    Track(
      id: 3,
      title: 'Indie Folk',
      artist: 'Les Collines',
      album: 'Horizon',
      hasCover: false,
      durationSeconds: 233,
      extension: '.flac',
    ),
  ];

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // Sans chargement explicite, `flutter test` rend des rectangles à la place
    // du texte et des icônes : la capture serait inexploitable pour comparer à
    // la planche.
    Future<ByteData> read(String path) async =>
        ByteData.view((await File(path).readAsBytes()).buffer);

    for (final path in const <String>[
      'assets/fonts/Sora-Regular.ttf',
      'assets/fonts/Sora-Medium.ttf',
      'assets/fonts/Sora-SemiBold.ttf',
    ]) {
      await (FontLoader('Sora')..addFont(read(path))).load();
    }

    // Police d'icônes du SDK Flutter — chemin déduit de l'exécutable courant
    // (`<flutterRoot>/bin/cache/dart-sdk/bin/dart`), donc valable sur toute
    // machine où `flutter test` tourne. La casse du fichier varie selon la
    // plateforme : on cherche au lieu de la coder en dur.
    Directory? fontsDir;
    var probe = File(Platform.resolvedExecutable).parent;
    for (var depth = 0; depth < 8 && fontsDir == null; depth++) {
      for (final candidate in <String>[
        '${probe.path}/material_fonts',
        '${probe.path}/artifacts/material_fonts',
      ]) {
        final directory = Directory(candidate);
        if (directory.existsSync()) {
          fontsDir = directory;
          break;
        }
      }
      probe = probe.parent;
    }
    final icons = fontsDir?.listSync().whereType<File>().where((file) {
      final name = file.uri.pathSegments.last.toLowerCase();
      return name.startsWith('materialicons') && name.endsWith('.otf');
    }).firstOrNull;
    if (icons != null) {
      await (FontLoader('MaterialIcons')..addFont(read(icons.path))).load();
    } else {
      // ignore: avoid_print
      print('[DIRECTION33] police d’icônes du SDK introuvable');
    }
  });

  Future<void> capture(
    WidgetTester tester, {
    required ThemeData theme,
    required String name,
  }) async {
    tester.view.physicalSize = const Size(1080, 2160);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...authOverrides(
            state: AuthState(
              AuthStatus.authenticated,
              user: makeUser(username: 'Romain'),
            ),
          ),
          libraryProvider.overrideWith((ref) => Future.value(tracks)),
          catalogRecentProvider.overrideWith(
            (ref) async => [
              for (final track in tracks)
                CatalogEntry(track: track, inMyLibrary: track.id == 3),
            ],
          ),
          mediaItemProvider.overrideWith(
            (ref) => Stream.value(
              const MediaItem(
                id: '2',
                title: 'Sunset Lover',
                artist: 'Petit Biscuit',
                duration: Duration(seconds: 220),
              ),
            ),
          ),
          playbackStateProvider.overrideWith(
            (ref) => Stream.value(
              PlaybackState(processingState: AudioProcessingState.ready),
            ),
          ),
          positionDataProvider.overrideWith(
            (ref) => Stream.value(
              const PlayerPositionData(
                position: Duration(seconds: 70),
                bufferedPosition: Duration(seconds: 120),
                duration: Duration(seconds: 220),
              ),
            ),
          ),
        ],
        child: MaterialApp(theme: theme, home: const HomeDashboardScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Accueil'), findsOneWidget);
    expect(find.text('Romain'), findsOneWidget);

    // Écrit le PNG sous `test/goldens/` avec `--update-goldens`, et sert
    // ensuite de garde-fou de non-régression visuelle.
    await expectLater(
      find.byType(HomeDashboardScreen),
      matchesGoldenFile('goldens/$name.png'),
    );
  }

  testWidgets('Accueil Direction 33 — thème clair', (tester) async {
    await capture(tester, theme: AppTheme.light, name: 'accueil-light');
  });

  testWidgets('Accueil Direction 33 — thème sombre', (tester) async {
    await capture(tester, theme: AppTheme.dark, name: 'accueil-dark');
  });
}
