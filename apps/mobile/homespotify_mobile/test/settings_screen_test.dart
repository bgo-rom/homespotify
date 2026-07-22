import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:homespotify_mobile/src/core/config/app_config.dart';
import 'package:homespotify_mobile/src/features/auth/application/auth_controller.dart';
import 'package:homespotify_mobile/src/features/library/domain/local_playlist.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_summary.dart';
import 'package:homespotify_mobile/src/features/player/audio/homespotify_audio_handler.dart';
import 'package:homespotify_mobile/src/features/settings/data/settings_server_checker.dart';
import 'package:homespotify_mobile/src/features/settings/presentation/settings_screen.dart';

import 'support/fake_auth.dart';
import 'support/noop_audio_handler.dart';
import 'support/test_overrides.dart';

void main() {
  Finder infoValue(String label, String value) => find.descendant(
    of: find.byKey(ValueKey<String>('settings-info-$label')).first,
    matching: find.text(value),
  );

  Future<void> pumpSettings(
    WidgetTester tester, {
    required SettingsServerChecker checker,
    String role = 'USER',
    Future<UserLibrarySummary> Function()? summaryLoader,
  }) async {
    // Surface haute : la section Sécurité ajoutée au-dessus ne doit pas
    // pousser les sections historiques hors du viewport (ListView lazy).
    await tester.binding.setSurfaceSize(const Size(400, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        // L-020 : un ProviderScope monté ignore de nouveaux overrides lors
        // d'un re-pump. La clé unique force un remontage complet quand un
        // même test enchaîne plusieurs rôles.
        key: UniqueKey(),
        overrides: [
          ...authOverrides(
            state: AuthState(
              AuthStatus.authenticated,
              user: makeUser(role: role),
            ),
          ),
          settingsServerCheckerProvider.overrideWithValue(checker),
          audioHandlerProvider.overrideWithValue(NoopHomeSpotifyAudioHandler()),
          ...libraryNetworkOverrides(
            favoriteIds: const <int>{1, 2, 3},
            playlists: const <LocalPlaylist>[
              LocalPlaylist(id: 'one', name: 'Une', trackIds: <int>[]),
              LocalPlaylist(id: 'two', name: 'Deux', trackIds: <int>[]),
            ],
            summary: const UserLibrarySummary(
              trackCount: 12,
              favoriteCount: 3,
              playlistCount: 2,
              logicalSizeBytes: 1572864,
            ),
            summaryLoader: summaryLoader,
          ),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('le service teste exclusivement GET /health', () async {
    late RequestOptions request;
    final dio = Dio(BaseOptions(baseUrl: 'http://server.test:3000'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          request = options;
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: const <String, dynamic>{'status': 'ok'},
            ),
          );
        },
      ),
    );

    await DioSettingsServerChecker(dio).checkHealth();

    expect(request.method, 'GET');
    expect(request.path, '/health');
  });

  testWidgets('affiche URL actuelle et compte favoris/playlists', (
    tester,
  ) async {
    await pumpSettings(tester, checker: _FakeChecker());

    expect(find.text('Paramètres'), findsOneWidget);
    expect(find.text(AppConfig.apiBaseUrl), findsOneWidget);
    expect(infoValue('Favoris', '3'), findsOneWidget);
    expect(infoValue('Playlists', '2'), findsOneWidget);
    expect(infoValue('Morceaux', '12'), findsOneWidget);
    expect(infoValue('Stockage logique', '1.5 Mo'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('WAV / FLAC'), 200);
    expect(find.text('WAV / FLAC'), findsOneWidget);
  });

  testWidgets('test serveur réussi affiche Connecté', (tester) async {
    final checker = _FakeChecker();
    await pumpSettings(tester, checker: checker);

    await tester.tap(find.text('Tester la connexion'));
    await tester.pumpAndSettle();

    expect(checker.calls, 1);
    expect(find.text('Connecté'), findsOneWidget);
  });

  testWidgets('serveur inaccessible affiche un message clair', (tester) async {
    final checker = _FakeChecker(error: StateError('hors ligne'));
    await pumpSettings(tester, checker: checker);

    await tester.tap(find.text('Tester la connexion'));
    await tester.pumpAndSettle();

    expect(find.text('Inaccessible'), findsOneWidget);
    expect(find.text(AppConfig.serverUnreachableMessage), findsOneWidget);
  });

  testWidgets('un test en cours bloque les lancements concurrents', (
    tester,
  ) async {
    final completer = Completer<void>();
    final checker = _FakeChecker(completer: completer);
    await pumpSettings(tester, checker: checker);

    await tester.tap(find.text('Tester la connexion'));
    await tester.pump();
    await tester.tap(find.text('Tester la connexion'));
    await tester.pump();

    expect(checker.calls, 1);
    expect(find.text('Test en cours'), findsOneWidget);

    completer.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('résumé du compte affiche le chargement', (tester) async {
    final completer = Completer<UserLibrarySummary>();
    addTearDown(() {
      if (!completer.isCompleted) {
        completer.complete(
          const UserLibrarySummary(
            trackCount: 0,
            favoriteCount: 0,
            playlistCount: 0,
            logicalSizeBytes: 0,
          ),
        );
      }
    });
    await pumpSettings(
      tester,
      checker: _FakeChecker(),
      summaryLoader: () => completer.future,
    );

    expect(infoValue('Bibliothèque', 'Chargement…'), findsOneWidget);
  });

  testWidgets('résumé en erreur permet une relance manuelle', (tester) async {
    var calls = 0;
    await pumpSettings(
      tester,
      checker: _FakeChecker(),
      summaryLoader: () async {
        calls += 1;
        if (calls == 1) throw StateError('indisponible');
        return const UserLibrarySummary(
          trackCount: 7,
          favoriteCount: 1,
          playlistCount: 1,
          logicalSizeBytes: 1024,
        );
      },
    );

    expect(find.text('Indisponible'), findsOneWidget);
    await tester.tap(find.text('Réessayer'));
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text('7'), findsOneWidget);
  });

  testWidgets('OWNER voit les demandes et imports, ADMIN et USER non', (
    tester,
  ) async {
    await pumpSettings(tester, checker: _FakeChecker(), role: 'OWNER');
    await tester.scrollUntilVisible(find.text('Administration'), 200);
    expect(find.text('Demandes musicales'), findsOneWidget);
    expect(find.text('Imports utilisateurs'), findsOneWidget);

    for (final role in ['ADMIN', 'USER']) {
      await pumpSettings(tester, checker: _FakeChecker(), role: role);
      expect(find.text('Demandes musicales'), findsNothing);
      expect(find.text('Imports utilisateurs'), findsNothing);
    }
  });
}

class _FakeChecker implements SettingsServerChecker {
  _FakeChecker({this.error, this.completer});

  final Object? error;
  final Completer<void>? completer;
  int calls = 0;

  @override
  Future<void> checkHealth() async {
    calls += 1;
    if (completer != null) await completer!.future;
    if (error != null) throw error!;
  }
}
