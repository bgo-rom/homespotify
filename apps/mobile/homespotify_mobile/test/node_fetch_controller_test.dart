import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homespotify_mobile/src/features/library/data/library_api.dart';
import 'package:homespotify_mobile/src/features/node_fetch/application/node_fetch_controller.dart';
import 'package:homespotify_mobile/src/features/node_fetch/data/node_fetch_api.dart';

class FakeNodeFetchRepository implements NodeFetchRepository {
  NodeFetchJob enqueueResult = const NodeFetchJob(
    id: 'job-1',
    status: NodeFetchJobStatus.queued,
  );
  NodeFetchApiException? enqueueError;
  final Completer<NodeFetchJob> statusCompleter = Completer<NodeFetchJob>();
  int enqueueCalls = 0;
  int statusCalls = 0;

  @override
  Future<NodeFetchJob> enqueue({
    required String url,
    required int userId,
  }) async {
    enqueueCalls += 1;
    final error = enqueueError;
    if (error != null) throw error;
    return enqueueResult;
  }

  @override
  Future<NodeFetchJob> fetchJob(String jobId) {
    statusCalls += 1;
    return statusCompleter.future;
  }
}

Future<void> waitForPhase(
  ProviderContainer container,
  NodeFetchPhase phase,
) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    if (container.read(nodeFetchControllerProvider).phase == phase) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('Phase $phase non atteinte.');
}

void main() {
  test(
    'affiche le 202 puis invalide la bibliothèque après dépôt inbox',
    () async {
      final repository = FakeNodeFetchRepository();
      var libraryLoads = 0;
      final container = ProviderContainer(
        overrides: [
          nodeFetchApiProvider.overrideWithValue(repository),
          nodeFetchPollIntervalProvider.overrideWithValue(Duration.zero),
          nodeFetchMaxPollAttemptsProvider.overrideWithValue(5),
          nodeFetchLibraryRefreshDelaysProvider.overrideWithValue(const [
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
          .read(nodeFetchControllerProvider.notifier)
          .submit(url: 'https://audio.example/track.flac', userId: 7);
      final accepted = container.read(nodeFetchControllerProvider);
      expect(accepted.phase, NodeFetchPhase.queued);
      expect(accepted.message, nodeFetchAcceptedMessage);

      repository.statusCompleter.complete(
        const NodeFetchJob(
          id: 'job-1',
          status: NodeFetchJobStatus.readyForImport,
          bytesReceived: 42,
          filename: 'track.flac',
        ),
      );
      await waitForPhase(container, NodeFetchPhase.readyForImport);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(
        container.read(nodeFetchControllerProvider).filename,
        'track.flac',
      );
      expect(libraryLoads, greaterThanOrEqualTo(2));

      subscription.close();
      container.dispose();
    },
  );

  test('refuse localement une URL non HTTPS sans appeler le dépôt', () async {
    final repository = FakeNodeFetchRepository();
    final container = ProviderContainer(
      overrides: [nodeFetchApiProvider.overrideWithValue(repository)],
    );
    await container
        .read(nodeFetchControllerProvider.notifier)
        .submit(url: 'http://audio.example/track.flac', userId: 1);
    final state = container.read(nodeFetchControllerProvider);
    expect(state.phase, NodeFetchPhase.failed);
    expect(state.message, contains('HTTPS'));
    expect(repository.enqueueCalls, 0);
    container.dispose();
  });

  test('présente proprement un refus du serveur', () async {
    final repository = FakeNodeFetchRepository()
      ..enqueueError = const NodeFetchApiException('Origine non autorisée.');
    final container = ProviderContainer(
      overrides: [nodeFetchApiProvider.overrideWithValue(repository)],
    );
    await container
        .read(nodeFetchControllerProvider.notifier)
        .submit(url: 'https://audio.example/track.flac', userId: 1);
    final state = container.read(nodeFetchControllerProvider);
    expect(state.phase, NodeFetchPhase.failed);
    expect(state.message, 'Origine non autorisée.');
    container.dispose();
  });
}
