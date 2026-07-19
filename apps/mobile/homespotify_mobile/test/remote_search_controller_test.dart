import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homespotify_mobile/src/features/library/data/library_api.dart';
import 'package:homespotify_mobile/src/features/node_fetch/data/node_fetch_api.dart';
import 'package:homespotify_mobile/src/features/remote_search/application/remote_search_controller.dart';
import 'package:homespotify_mobile/src/features/remote_search/data/remote_search_api.dart';
import 'package:homespotify_mobile/src/features/remote_search/domain/remote_track.dart';

class FakeRemoteSearchRepository implements RemoteSearchRepository {
  List<RemoteTrack> searchResult = const [
    RemoteTrack(trackId: 'track-1', title: 'Titre', artist: 'Artiste'),
  ];
  RemoteSearchApiException? searchError;
  RemoteSearchApiException? importError;
  final Completer<NodeFetchJob> status = Completer<NodeFetchJob>();
  int searchCalls = 0;
  int importCalls = 0;

  @override
  Future<List<RemoteTrack>> search(String query) async {
    searchCalls += 1;
    final error = searchError;
    if (error != null) throw error;
    return searchResult;
  }

  @override
  Future<NodeFetchJob> importTrack(String trackId) async {
    importCalls += 1;
    final error = importError;
    if (error != null) throw error;
    return const NodeFetchJob(id: 'job-1', status: NodeFetchJobStatus.queued);
  }

  @override
  Future<NodeFetchJob> fetchImportJob(String jobId) => status.future;
}

Future<void> waitForImportPhase(
  ProviderContainer container,
  String trackId,
  RemoteImportPhase phase,
) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    if (container
            .read(remoteSearchControllerProvider)
            .imports[trackId]
            ?.phase ==
        phase) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('Phase $phase non atteinte pour $trackId.');
}

void main() {
  test('recherche puis suit le 202 jusqu’au dépôt dans l’inbox', () async {
    final repository = FakeRemoteSearchRepository();
    var libraryLoads = 0;
    final container = ProviderContainer(
      overrides: [
        remoteSearchApiProvider.overrideWithValue(repository),
        remoteImportPollIntervalProvider.overrideWithValue(Duration.zero),
        remoteImportMaxPollAttemptsProvider.overrideWithValue(5),
        remoteImportLibraryRefreshDelaysProvider.overrideWithValue(const [
          Duration.zero,
        ]),
        libraryProvider.overrideWith((ref) async {
          libraryLoads += 1;
          return const [];
        }),
      ],
    );
    final subscription = container.listen(libraryProvider, (_, _) {});
    await container.read(libraryProvider.future);

    await container
        .read(remoteSearchControllerProvider.notifier)
        .search('Titre');
    expect(
      container.read(remoteSearchControllerProvider).results,
      hasLength(1),
    );

    await container
        .read(remoteSearchControllerProvider.notifier)
        .importTrack('track-1');
    final accepted = container
        .read(remoteSearchControllerProvider)
        .imports['track-1'];
    expect(accepted?.phase, RemoteImportPhase.queued);
    expect(accepted?.message, remoteImportAcceptedMessage);

    repository.status.complete(
      const NodeFetchJob(
        id: 'job-1',
        status: NodeFetchJobStatus.readyForImport,
        filename: 'titre.flac',
        bytesReceived: 42,
      ),
    );
    await waitForImportPhase(
      container,
      'track-1',
      RemoteImportPhase.readyForImport,
    );
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(libraryLoads, greaterThanOrEqualTo(2));

    subscription.close();
    container.dispose();
  });

  test('refuse une recherche trop courte sans appel réseau', () async {
    final repository = FakeRemoteSearchRepository();
    final container = ProviderContainer(
      overrides: [remoteSearchApiProvider.overrideWithValue(repository)],
    );
    await container.read(remoteSearchControllerProvider.notifier).search('a');
    expect(container.read(remoteSearchControllerProvider).error, contains('2'));
    expect(repository.searchCalls, 0);
    container.dispose();
  });

  test('affiche proprement une erreur de recherche distante', () async {
    final repository = FakeRemoteSearchRepository()
      ..searchError = const RemoteSearchApiException('Nœud indisponible.');
    final container = ProviderContainer(
      overrides: [remoteSearchApiProvider.overrideWithValue(repository)],
    );
    await container
        .read(remoteSearchControllerProvider.notifier)
        .search('Artiste');
    expect(
      container.read(remoteSearchControllerProvider).error,
      'Nœud indisponible.',
    );
    container.dispose();
  });
}
