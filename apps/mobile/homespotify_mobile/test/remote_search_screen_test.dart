import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homespotify_mobile/src/features/node_fetch/data/node_fetch_api.dart';
import 'package:homespotify_mobile/src/features/remote_search/application/remote_search_controller.dart';
import 'package:homespotify_mobile/src/features/remote_search/data/remote_search_api.dart';
import 'package:homespotify_mobile/src/features/remote_search/domain/remote_track.dart';
import 'package:homespotify_mobile/src/features/remote_search/presentation/remote_search_screen.dart';

class FakeRemoteSearchRepository implements RemoteSearchRepository {
  final Completer<NodeFetchJob> status = Completer<NodeFetchJob>();
  int importCalls = 0;

  @override
  Future<List<RemoteTrack>> search(String query) async => const [
    RemoteTrack(
      trackId: 'track-widget',
      title: 'Titre distant',
      artist: 'Artiste distant',
    ),
  ];

  @override
  Future<NodeFetchJob> importTrack(String trackId) async {
    importCalls += 1;
    return const NodeFetchJob(
      id: 'job-widget',
      status: NodeFetchJobStatus.queued,
    );
  }

  @override
  Future<NodeFetchJob> fetchImportJob(String jobId) => status.future;
}

Widget makeApp(FakeRemoteSearchRepository repository) {
  return ProviderScope(
    overrides: [
      remoteSearchApiProvider.overrideWithValue(repository),
      remoteImportPollIntervalProvider.overrideWithValue(Duration.zero),
      remoteImportMaxPollAttemptsProvider.overrideWithValue(5),
      remoteImportLibraryRefreshDelaysProvider.overrideWithValue(const []),
    ],
    child: const MaterialApp(home: RemoteSearchScreen()),
  );
}

void main() {
  testWidgets('affiche les résultats puis le statut 202 par piste', (
    tester,
  ) async {
    final repository = FakeRemoteSearchRepository();
    await tester.pumpWidget(makeApp(repository));
    await tester.enterText(
      find.byKey(const ValueKey('remote-search-field')),
      'Titre',
    );
    await tester.tap(find.byKey(const ValueKey('remote-search-submit')));
    await tester.pump();
    await tester.pump();
    expect(find.text('Titre distant'), findsOneWidget);
    expect(find.text('Artiste distant'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('remote-import-track-widget')));
    await tester.pump();
    expect(find.text(remoteImportAcceptedMessage), findsOneWidget);
    expect(repository.importCalls, 1);

    repository.status.complete(
      const NodeFetchJob(
        id: 'job-widget',
        status: NodeFetchJobStatus.readyForImport,
        filename: 'titre.flac',
        bytesReceived: 1024,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.textContaining('watcher'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('remote-import-ready-track-widget')),
      findsOneWidget,
    );
  });

  testWidgets('une recherche trop courte affiche la validation locale', (
    tester,
  ) async {
    final repository = FakeRemoteSearchRepository();
    await tester.pumpWidget(makeApp(repository));
    await tester.enterText(
      find.byKey(const ValueKey('remote-search-field')),
      'a',
    );
    await tester.tap(find.byKey(const ValueKey('remote-search-submit')));
    await tester.pump();
    expect(find.textContaining('entre 2 et 200'), findsOneWidget);
  });
}
