import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:homespotify_mobile/src/features/admin/data/admin_api.dart';
import 'package:homespotify_mobile/src/features/admin/presentation/admin_imports_screen.dart';
import 'package:homespotify_mobile/src/features/admin/presentation/admin_music_requests_screen.dart';
import 'package:homespotify_mobile/src/features/auth/application/auth_controller.dart';

import 'support/fake_auth.dart';

void main() {
  Widget ownerApp(AdminApi api, Widget child) => ProviderScope(
    overrides: [
      ...authOverrides(
        state: AuthState(
          AuthStatus.authenticated,
          user: makeUser(role: 'OWNER'),
        ),
      ),
      adminApiProvider.overrideWithValue(api),
    ],
    child: MaterialApp(home: child),
  );

  testWidgets('OWNER ouvre le lien et associe une piste recherchée', (
    tester,
  ) async {
    final api = _FakeAdminApi();
    String? openedUrl;
    const channel = MethodChannel('com.homespotify/external_url');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      openedUrl = (call.arguments as Map<dynamic, dynamic>)['url'] as String?;
      return true;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );

    await tester.pumpWidget(ownerApp(api, const AdminMusicRequestsScreen()));
    await tester.pumpAndSettle();
    // Le titre de la demande est désormais rendu « titre — artiste ».
    await tester.tap(find.textContaining('Playlist été'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('open-request-external-url')));
    await tester.pump();
    expect(openedUrl, 'https://example.test/playlist/42');

    await tester.tap(find.text('1. Titre cible'));
    await tester.enterText(
      find.byKey(const Key('admin-track-search-field')),
      'titre cible',
    );
    // Deux icônes de recherche existent (filtre de liste + champ piste) :
    // viser le bouton du champ de recherche de piste.
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('admin-track-search-field')),
        matching: find.byIcon(Icons.search_rounded),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Piste existante'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Associer'));
    await tester.pumpAndSettle();
    expect(api.assignedRequest, (requestId: 10, itemId: 100, trackId: 900));
  });

  testWidgets('OWNER voit le détail d’un import et ses actions', (
    tester,
  ) async {
    final api = _FakeAdminApi();
    await tester.pumpWidget(ownerApp(api, const AdminImportsScreen()));
    await tester.pumpAndSettle();

    expect(find.text('fixture.wav'), findsOneWidget);
    expect(
      find.textContaining('Alice · WAITING_FOR_OWNER_MATCH'),
      findsOneWidget,
    );
    await tester.tap(find.text('fixture.wav'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Dossier : 7_alice/inbox'), findsOneWidget);
    expect(
      find.textContaining('Titre importé · Artiste importé'),
      findsOneWidget,
    );
    expect(find.text('Réessayer'), findsOneWidget);
    expect(find.text('Déplacer vers rejected'), findsOneWidget);
    expect(find.byKey(const Key('import-track-search')), findsOneWidget);
  });

  testWidgets('Imports : les filtres ne débordent pas sur téléphone étroit', (
    tester,
  ) async {
    // Largeur réelle du téléphone de test : les deux DropdownButtonFormField
    // côte à côte débordaient (OVERFLOWED BY 87 / 3.2).
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ownerApp(_FakeAdminApi(), const AdminImportsScreen()),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Tous les statuts'), findsOneWidget);
    expect(find.text('Tous les utilisateurs'), findsOneWidget);
    // Sous 600 dp les filtres sont EMPILÉS (aucun Row côte à côte).
    expect(find.byType(DropdownButtonFormField<String?>), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<int?>), findsOneWidget);
  });

  testWidgets('Imports : filtres côte à côte au-delà de 600 dp', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ownerApp(_FakeAdminApi(), const AdminImportsScreen()),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Tous les statuts'), findsOneWidget);
    expect(find.text('Tous les utilisateurs'), findsOneWidget);
  });
}

class _FakeAdminApi extends AdminApi {
  _FakeAdminApi() : super(Dio());

  ({int requestId, int itemId, int trackId})? assignedRequest;

  final request = const AdminMusicRequest(
    id: 10,
    requesterName: 'Alice',
    requesterId: 7,
    requesterUsername: 'alice',
    title: 'Playlist été',
    artist: 'Artiste cible',
    album: 'Album cible',
    itemType: 'PLAYLIST',
    status: 'REVIEWING',
    createdAt: '2026-07-14T12:00:00Z',
    presentInRequesterLibrary: false,
    requestedItemCount: 1,
    completedItemCount: 0,
    unavailableItemCount: 0,
    externalUrl: 'https://example.test/playlist/42',
    items: [
      AdminMusicRequestItem(
        id: 100,
        position: 1,
        title: 'Titre cible',
        artist: 'Artiste cible',
        status: 'PENDING',
        presentInRequesterLibrary: false,
      ),
    ],
  );

  final import = const AdminImportJob(
    id: 20,
    userId: 7,
    requesterName: 'Alice',
    filename: 'fixture.wav',
    relativePath: '7_alice/inbox/fixture.wav',
    directoryPath: '7_alice/inbox',
    status: 'WAITING_FOR_OWNER_MATCH',
    createdAt: '2026-07-14T12:00:00Z',
    sizeBytes: 2048,
    metadata: {
      'title': 'Titre importé',
      'artist': 'Artiste importé',
      'album': 'Album importé',
      'container': 'WAVE',
    },
    availableRequestItems: [
      AdminImportRequestItem(
        id: 100,
        requestId: 10,
        position: 1,
        title: 'Titre cible',
      ),
    ],
  );

  @override
  Future<List<AdminMusicRequest>> listMusicRequests({
    int? userId,
    String? type,
    String? status,
    String? query,
  }) async => [request];

  @override
  Future<List<AdminImportJob>> listImports({
    int? userId,
    String? status,
  }) async => [import];

  @override
  Future<List<AdminTrackSearchResult>> searchTracks(String query) async =>
      const [
        AdminTrackSearchResult(
          id: 900,
          title: 'Piste existante',
          artist: 'Artiste cible',
          album: 'Album cible',
        ),
      ];

  @override
  Future<void> assignTrack(int requestId, int itemId, int trackId) async {
    assignedRequest = (requestId: requestId, itemId: itemId, trackId: trackId);
  }
}
