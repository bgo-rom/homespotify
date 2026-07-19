import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:homespotify_mobile/src/features/admin/presentation/admin_guard.dart';
import 'package:homespotify_mobile/src/features/auth/application/auth_controller.dart';
import 'package:homespotify_mobile/src/features/settings/presentation/settings_screen.dart';

import 'support/fake_auth.dart';
import 'support/test_overrides.dart';

Future<void> pumpSettingsAs(WidgetTester tester, AuthState authState) async {
  await tester.binding.setSurfaceSize(const Size(400, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...authOverrides(state: authState),
        ...libraryNetworkOverrides(),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('OWNER : la section Administration est visible', (tester) async {
    await pumpSettingsAs(
      tester,
      AuthState(AuthStatus.authenticated, user: makeUser(role: 'OWNER')),
    );
    expect(find.text('Administration'), findsOneWidget);
    expect(find.text('Tableau de bord'), findsOneWidget);
    expect(find.text('Demandes musicales'), findsOneWidget);
    expect(find.text('Diagnostics recommandations'), findsOneWidget);
    expect(find.text('OWNER'), findsOneWidget);
  });

  testWidgets('USER : aucune section Administration', (tester) async {
    await pumpSettingsAs(
      tester,
      AuthState(
        AuthStatus.authenticated,
        user: makeUser(role: 'USER', username: 'invite'),
      ),
    );
    expect(find.text('Administration'), findsNothing);
    expect(find.text('Tableau de bord'), findsNothing);
    expect(find.text('Demandes musicales'), findsNothing);
    expect(find.text('Diagnostics recommandations'), findsNothing);
  });

  testWidgets('ADMIN : aucune section Administration non plus', (tester) async {
    await pumpSettingsAs(
      tester,
      AuthState(
        AuthStatus.authenticated,
        user: makeUser(role: 'ADMIN', username: 'gerant'),
      ),
    );
    expect(find.text('Administration'), findsNothing);
  });

  testWidgets('AdminGuard bloque un non-OWNER même en accès direct', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: authOverrides(
          state: AuthState(
            AuthStatus.authenticated,
            user: makeUser(role: 'ADMIN', username: 'gerant'),
          ),
        ),
        child: const MaterialApp(
          home: AdminGuard(child: Text('CONTENU ADMIN')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('CONTENU ADMIN'), findsNothing);
    expect(
      find.text('Accès réservé au propriétaire de HomeSpotify.'),
      findsOneWidget,
    );
  });

  testWidgets('AdminGuard laisse passer le OWNER', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: authOverrides(
          state: AuthState(AuthStatus.authenticated, user: makeUser()),
        ),
        child: const MaterialApp(
          home: AdminGuard(child: Text('CONTENU ADMIN')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('CONTENU ADMIN'), findsOneWidget);
  });
}
