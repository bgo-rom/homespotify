import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:homespotify_mobile/src/features/auth/application/auth_controller.dart';
import 'package:homespotify_mobile/src/features/profile/presentation/profile_screen.dart';

import 'support/fake_auth.dart';

/// Routeur minimal : le profil pousse des routes, il lui faut un GoRouter.
Widget makeProfileApp() {
  final router = GoRouter(
    initialLocation: '/profile',
    routes: [
      GoRoute(path: '/profile', builder: (_, _) => const ProfileScreen()),
      GoRoute(
        path: '/catalog-search',
        builder: (_, _) => const Scaffold(body: Text('recherche distante')),
      ),
      GoRoute(
        path: '/settings',
        builder: (_, _) => const Scaffold(body: Text('paramètres')),
      ),
    ],
  );
  return ProviderScope(
    overrides: authOverrides(
      state: AuthState(AuthStatus.authenticated, user: makeUser()),
    ),
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  testWidgets('le profil ne contient plus aucun raccourci de demande '
      'ni d’import séparé', (tester) async {
    await tester.pumpWidget(makeProfileApp());
    await tester.pumpAndSettle();

    for (final label in [
      'Mes demandes',
      'Télécharger un lien',
      'Importer une musique',
      'File d’installation',
      'Demandes musicales',
    ]) {
      expect(find.text(label), findsNothing, reason: '« $label » doit avoir disparu');
    }
    // Les anciennes clés de widget ne doivent plus exister nulle part.
    for (final key in [
      'profile-remote-download-action',
      'profile-import-action',
      'profile-queue-action',
    ]) {
      expect(find.byKey(ValueKey(key)), findsNothing);
    }
  });

  testWidgets('le profil mène à l’unique écran de recherche distante', (
    tester,
  ) async {
    await tester.pumpWidget(makeProfileApp());
    await tester.pumpAndSettle();

    final action = find.byKey(const ValueKey('profile-add-music-action'));
    expect(action, findsOneWidget);
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(find.text('recherche distante'), findsOneWidget);
  });
}
