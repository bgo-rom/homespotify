import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homespotify_mobile/src/features/auth/application/auth_controller.dart';
import 'package:homespotify_mobile/src/features/node_fetch/application/node_fetch_controller.dart';
import 'package:homespotify_mobile/src/features/node_fetch/data/node_fetch_api.dart';
import 'package:homespotify_mobile/src/features/node_fetch/presentation/node_fetch_screen.dart';

import 'support/fake_auth.dart';

class FakeNodeFetchRepository implements NodeFetchRepository {
  final Completer<NodeFetchJob> status = Completer<NodeFetchJob>();
  int enqueueCalls = 0;

  @override
  Future<NodeFetchJob> enqueue({
    required String url,
    required int userId,
  }) async {
    enqueueCalls += 1;
    return const NodeFetchJob(
      id: 'job-widget',
      status: NodeFetchJobStatus.queued,
    );
  }

  @override
  Future<NodeFetchJob> fetchJob(String jobId) => status.future;
}

Widget makeApp(FakeNodeFetchRepository repository) {
  final user = makeUser(id: 11, username: 'listener', role: 'USER');
  return ProviderScope(
    overrides: [
      ...authOverrides(state: AuthState(AuthStatus.authenticated, user: user)),
      nodeFetchApiProvider.overrideWithValue(repository),
      nodeFetchPollIntervalProvider.overrideWithValue(Duration.zero),
      nodeFetchMaxPollAttemptsProvider.overrideWithValue(5),
      nodeFetchLibraryRefreshDelaysProvider.overrideWithValue(const []),
    ],
    child: const MaterialApp(home: NodeFetchScreen()),
  );
}

void main() {
  testWidgets('affiche le message 202 puis le passage de relais au watcher', (
    tester,
  ) async {
    final repository = FakeNodeFetchRepository();
    await tester.pumpWidget(makeApp(repository));
    await tester.enterText(
      find.byKey(const ValueKey('node-fetch-url-field')),
      'https://audio.example/track.flac',
    );
    await tester.tap(find.byKey(const ValueKey('node-fetch-submit')));
    await tester.pump();
    await tester.pump();
    expect(find.text(nodeFetchAcceptedMessage), findsOneWidget);
    expect(repository.enqueueCalls, 1);

    repository.status.complete(
      const NodeFetchJob(
        id: 'job-widget',
        status: NodeFetchJobStatus.readyForImport,
        filename: 'track.flac',
        bytesReceived: 1024,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.textContaining('watcher HomeSpotify'), findsOneWidget);
    expect(find.text('track.flac'), findsOneWidget);
    expect(find.text('1 Ko reçus'), findsOneWidget);
  });

  testWidgets('bloque une URL HTTP avant l’appel réseau', (tester) async {
    final repository = FakeNodeFetchRepository();
    await tester.pumpWidget(makeApp(repository));
    await tester.enterText(
      find.byKey(const ValueKey('node-fetch-url-field')),
      'http://audio.example/track.flac',
    );
    await tester.tap(find.byKey(const ValueKey('node-fetch-submit')));
    await tester.pump();
    expect(find.textContaining('URL HTTPS valide'), findsOneWidget);
    expect(repository.enqueueCalls, 0);
  });
}
