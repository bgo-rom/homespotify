import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:homespotify_mobile/src/features/auth/application/auth_controller.dart';
import 'package:homespotify_mobile/src/features/auth/data/token_store.dart';
import 'package:homespotify_mobile/src/features/library/data/library_api.dart';
import 'package:homespotify_mobile/src/features/library/domain/local_playlist.dart';
import 'package:homespotify_mobile/src/features/library/domain/track.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_favorites.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_playlists.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_summary.dart';

import 'support/fake_auth.dart';
import 'support/fake_library_repositories.dart';

/// Laisse le microtask d'initialisation et les Futures internes se résoudre.
Future<void> settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late FakeTokenStore store;
  late FakeBiometricService biometrics;
  late FakeAuthApi api;
  late FakeSessionManager sessionManager;
  late ProviderContainer container;
  late int audioPurgeCalls;

  ProviderContainer makeContainer() {
    return ProviderContainer(
      overrides: [
        ...authOverrides(
          tokenStore: store,
          biometrics: biometrics,
          api: api,
          sessionManager: sessionManager,
        ),
        audioLogoutPurgeProvider.overrideWithValue(() async {
          audioPurgeCalls += 1;
        }),
      ],
    );
  }

  setUp(() {
    store = FakeTokenStore();
    biometrics = FakeBiometricService();
    api = FakeAuthApi();
    sessionManager = FakeSessionManager(store: store);
    audioPurgeCalls = 0;
  });

  tearDown(() => container.dispose());

  test(
    'sans session : bootstrapRequired quand le serveur n’a aucun compte',
    () async {
      api.bootstrapRequiredResult = true;
      container = makeContainer();
      container.read(authControllerProvider);
      await settle();
      expect(
        container.read(authControllerProvider).status,
        AuthStatus.bootstrapRequired,
      );
    },
  );

  test('sans session : unauthenticated quand un compte existe déjà', () async {
    container = makeContainer();
    container.read(authControllerProvider);
    await settle();
    expect(
      container.read(authControllerProvider).status,
      AuthStatus.unauthenticated,
    );
  });

  test(
    'erreur réseau au démarrage : état error avec message propre, puis retry',
    () async {
      api.networkDown = true;
      container = makeContainer();
      container.read(authControllerProvider);
      await settle();
      final state = container.read(authControllerProvider);
      expect(state.status, AuthStatus.error);
      expect(state.message, 'Serveur HomeSpotify inaccessible.');

      api.networkDown = false;
      await container.read(authControllerProvider.notifier).retry();
      await settle();
      expect(
        container.read(authControllerProvider).status,
        AuthStatus.unauthenticated,
      );
    },
  );

  test('bootstrap réussi : session stockée et état authenticated', () async {
    api.bootstrapRequiredResult = true;
    api.bootstrapResult = FakeAuthApi.payloadFor(makeUser());
    container = makeContainer();
    container.read(authControllerProvider);
    await settle();

    await container
        .read(authControllerProvider.notifier)
        .bootstrap(
          username: 'romain',
          displayName: 'Romain',
          password: 'motdepasse-owner-1',
          passwordConfirmation: 'motdepasse-owner-1',
        );

    final state = container.read(authControllerProvider);
    expect(state.status, AuthStatus.authenticated);
    expect(state.user?.isOwner, isTrue);
    expect(store.tokens?.accessToken, 'access');
  });

  test(
    'login réussi : authenticated ; échec : message générique affiché',
    () async {
      container = makeContainer();
      container.read(authControllerProvider);
      await settle();
      final controller = container.read(authControllerProvider.notifier);

      await controller.login(username: 'romain', password: 'mauvais');
      var state = container.read(authControllerProvider);
      expect(state.status, AuthStatus.unauthenticated);
      expect(state.message, 'Identifiants invalides.');

      api.loginResult = FakeAuthApi.payloadFor(makeUser());
      await controller.login(
        username: 'romain',
        password: 'motdepasse-owner-1',
      );
      state = container.read(authControllerProvider);
      expect(state.status, AuthStatus.authenticated);
      expect(state.message, isNull);
    },
  );

  test('restauration de session au démarrage via /me', () async {
    store.tokens = const AuthTokens(accessToken: 'a', refreshToken: 'r');
    api.meResult = makeUser();
    container = makeContainer();
    container.read(authControllerProvider);
    await settle();
    final state = container.read(authControllerProvider);
    expect(state.status, AuthStatus.authenticated);
    expect(state.user?.username, 'romain');
  });

  test('session stockée invalide : retour propre à unauthenticated', () async {
    store.tokens = const AuthTokens(accessToken: 'mort', refreshToken: 'mort');
    container = makeContainer();
    container.read(authControllerProvider);
    await settle();
    expect(
      container.read(authControllerProvider).status,
      AuthStatus.unauthenticated,
    );
    expect(store.tokens, isNull);
  });

  test(
    'mustChangePassword : état passwordChangeRequired puis authenticated',
    () async {
      container = makeContainer();
      container.read(authControllerProvider);
      await settle();
      final controller = container.read(authControllerProvider.notifier);

      api.loginResult = FakeAuthApi.payloadFor(
        makeUser(mustChangePassword: true),
      );
      await controller.login(username: 'invite', password: 'motdepasse-temp-1');
      expect(
        container.read(authControllerProvider).status,
        AuthStatus.passwordChangeRequired,
      );

      api.changePasswordResult = FakeAuthApi.payloadFor(makeUser(role: 'USER'));
      await controller.changePassword(
        currentPassword: 'motdepasse-temp-1',
        newPassword: 'motdepasse-final-1',
        newPasswordConfirmation: 'motdepasse-final-1',
      );
      expect(
        container.read(authControllerProvider).status,
        AuthStatus.authenticated,
      );
    },
  );

  testWidgets(
    'change-password monte la bibliothèque sans mutation Riverpod pendant build',
    (tester) async {
      container = ProviderContainer(
        overrides: [
          ...authOverrides(
            tokenStore: store,
            biometrics: biometrics,
            api: api,
            sessionManager: sessionManager,
          ),
          audioLogoutPurgeProvider.overrideWithValue(() async {}),
          libraryProvider.overrideWith((ref) async => const <Track>[]),
        ],
      );
      // `settle()` repose sur des timers Duration.zero : dans la zone
      // fake-async de testWidgets ils ne tirent jamais avant un pump —
      // runAsync exécute cette phase de préparation en asynchrone réel.
      await tester.runAsync(() async {
        container.read(authControllerProvider);
        await settle();
        api.loginResult = FakeAuthApi.payloadFor(
          makeUser(mustChangePassword: true),
        );
        await container
            .read(authControllerProvider.notifier)
            .login(username: 'invite', password: 'motdepasse-temp-1');
      });
      api.changePasswordResult = FakeAuthApi.payloadFor(makeUser(role: 'USER'));

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: _PasswordTransitionProbe()),
        ),
      );
      await tester.tap(find.byKey(const Key('change-password-probe')));
      await tester.pumpAndSettle();

      expect(find.text('Bibliothèque montée'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test('déconnexion : logout serveur + session locale effacée', () async {
    store.tokens = const AuthTokens(accessToken: 'a', refreshToken: 'r');
    api.meResult = makeUser();
    container = makeContainer();
    container.read(authControllerProvider);
    await settle();

    await container.read(authControllerProvider.notifier).logout();
    expect(
      container.read(authControllerProvider).status,
      AuthStatus.unauthenticated,
    );
    expect(api.logoutCalls, 1);
    expect(store.tokens, isNull);
    expect(audioPurgeCalls, 1);
  });

  test('logout invalide toutes les données personnelles sans flash', () async {
    store.tokens = const AuthTokens(accessToken: 'a', refreshToken: 'r');
    api.meResult = makeUser();
    container = ProviderContainer(
      overrides: [
        ...authOverrides(
          tokenStore: store,
          biometrics: biometrics,
          api: api,
          sessionManager: sessionManager,
        ),
        audioLogoutPurgeProvider.overrideWithValue(() async {
          audioPurgeCalls += 1;
        }),
        libraryProvider.overrideWith(
          (ref) async => const <Track>[
            Track(
              id: 1,
              title: 'Compte précédent',
              artist: 'Privé',
              album: '',
              hasCover: false,
              durationSeconds: 1,
            ),
          ],
        ),
        favoritesApiProvider.overrideWithValue(
          FakeFavoritesRepository(<int>{1}),
        ),
        playlistsApiProvider.overrideWithValue(
          FakePlaylistsRepository(const <LocalPlaylist>[
            LocalPlaylist(id: '1', name: 'Privée', trackIds: <int>[1]),
          ]),
        ),
        userLibrarySummaryProvider.overrideWith(
          (ref) async => const UserLibrarySummary(
            trackCount: 1,
            favoriteCount: 1,
            playlistCount: 1,
            logicalSizeBytes: 10,
          ),
        ),
      ],
    );
    container.read(authControllerProvider);
    await settle();
    await Future.wait<void>(<Future<void>>[
      container.read(libraryProvider.future).then((_) {}),
      container.read(favoriteTrackIdsProvider.future).then((_) {}),
      container.read(playlistsProvider.future).then((_) {}),
      container.read(userLibrarySummaryProvider.future).then((_) {}),
    ]);

    await container.read(authControllerProvider.notifier).logout();

    expect(
      container.read(authControllerProvider).status,
      AuthStatus.unauthenticated,
    );
    expect(container.read(libraryProvider).isLoading, isTrue);
    expect(container.read(favoriteTrackIdsProvider).isLoading, isTrue);
    expect(container.read(playlistsProvider).isLoading, isTrue);
    expect(container.read(userLibrarySummaryProvider).isLoading, isTrue);
    expect(audioPurgeCalls, 1);
  });

  test(
    'biométrie indisponible : session restaurée directement, jamais locked',
    () async {
      store.tokens = const AuthTokens(accessToken: 'a', refreshToken: 'r');
      store.biometricEnabled = true;
      biometrics.supported = false;
      api.meResult = makeUser();
      container = makeContainer();
      container.read(authControllerProvider);
      await settle();
      expect(
        container.read(authControllerProvider).status,
        AuthStatus.authenticated,
      );
    },
  );

  test(
    'biométrie active : verrou au démarrage, échec sans crash, succès déverrouille',
    () async {
      store.tokens = const AuthTokens(accessToken: 'a', refreshToken: 'r');
      store.biometricEnabled = true;
      biometrics.supported = true;
      api.meResult = makeUser();
      container = makeContainer();
      container.read(authControllerProvider);
      await settle();
      expect(container.read(authControllerProvider).status, AuthStatus.locked);

      // Échec/annulation : on reste verrouillé, sans crash ni déconnexion.
      biometrics.authenticateResult = false;
      await container
          .read(authControllerProvider.notifier)
          .unlockWithBiometrics();
      await settle();
      expect(container.read(authControllerProvider).status, AuthStatus.locked);

      biometrics.authenticateResult = true;
      await container
          .read(authControllerProvider.notifier)
          .unlockWithBiometrics();
      await settle();
      expect(
        container.read(authControllerProvider).status,
        AuthStatus.authenticated,
      );
    },
  );

  test('activer la biométrie exige une authentification réussie', () async {
    container = makeContainer();
    container.read(authControllerProvider);
    await settle();
    final controller = container.read(authControllerProvider.notifier);

    biometrics.supported = false;
    expect((await controller.setBiometricEnabled(true)).succeeded, isFalse);

    biometrics.supported = true;
    biometrics.authenticateResult = false;
    expect((await controller.setBiometricEnabled(true)).succeeded, isFalse);
    expect(store.biometricEnabled, isFalse);

    biometrics.authenticateResult = true;
    expect((await controller.setBiometricEnabled(true)).succeeded, isTrue);
    expect(store.biometricEnabled, isTrue);

    expect((await controller.setBiometricEnabled(false)).succeeded, isTrue);
    expect(store.biometricEnabled, isFalse);
  });

  test(
    'depuis le verrou, revenir au mot de passe supprime seulement la session',
    () async {
      store.tokens = const AuthTokens(accessToken: 'a', refreshToken: 'r');
      store.biometricEnabled = true;
      biometrics.supported = true;
      api.meResult = makeUser();
      container = makeContainer();
      container.read(authControllerProvider);
      await settle();
      expect(container.read(authControllerProvider).status, AuthStatus.locked);

      await container
          .read(authControllerProvider.notifier)
          .usePasswordInstead();

      expect(
        container.read(authControllerProvider).status,
        AuthStatus.unauthenticated,
      );
      expect(store.tokens, isNull);
      expect(store.biometricEnabled, isTrue);
    },
  );
}

class _PasswordTransitionProbe extends ConsumerWidget {
  const _PasswordTransitionProbe();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(
      authControllerProvider.select((state) => state.status),
    );
    if (status == AuthStatus.authenticated) {
      ref.watch(libraryProvider);
      return const Text('Bibliothèque montée');
    }
    return ElevatedButton(
      key: const Key('change-password-probe'),
      onPressed: () async {
        await ref
            .read(authControllerProvider.notifier)
            .changePassword(
              currentPassword: 'motdepasse-temp-1',
              newPassword: 'motdepasse-final-1',
              newPasswordConfirmation: 'motdepasse-final-1',
            );
      },
      child: const Text('Changer'),
    );
  }
}
