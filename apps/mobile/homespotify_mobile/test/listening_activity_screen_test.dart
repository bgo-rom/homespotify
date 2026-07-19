import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:homespotify_mobile/src/features/listening/data/listening_activity_api.dart';
import 'package:homespotify_mobile/src/features/listening/domain/listening_activity.dart';
import 'package:homespotify_mobile/src/features/listening/presentation/listening_activity_screen.dart';

void main() {
  testWidgets('affiche chargement puis état vide', (tester) async {
    final completer = Completer<ListeningActivityPage>();
    await tester.pumpWidget(_app(_FakeActivityApi(() => completer.future)));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    completer.complete(
      const ListeningActivityPage(items: [], nextCursor: null),
    );
    await tester.pumpAndSettle();
    expect(find.text('Aucune écoute enregistrée'), findsOneWidget);
  });

  testWidgets('affiche erreur et bouton Réessayer', (tester) async {
    await tester.pumpWidget(
      _app(
        _FakeActivityApi(
          () async => throw const ListeningActivityApiException('offline'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Impossible de charger l’activité d’écoute.'),
      findsOneWidget,
    );
    expect(find.text('Réessayer'), findsOneWidget);
  });

  testWidgets('affiche historique, durée écoutée et progression', (
    tester,
  ) async {
    final session = ListeningSession(
      id: 1,
      track: const ListeningTrack(
        id: 67,
        title: 'Hurt me anymore',
        artist: 'Artiste',
        album: 'Album',
        durationMs: 120000,
        coverUrl: null,
        available: true,
      ),
      startedAt: DateTime.now(),
      lastActivityAt: DateTime.now(),
      listenedMs: 45000,
      positionMs: 60000,
      durationMs: 120000,
      status: 'PAUSED',
      endReason: null,
      qualifiedPlay: true,
      completed: false,
    );
    await tester.pumpWidget(
      _app(
        _FakeActivityApi(
          () async => ListeningActivityPage(items: [session], nextCursor: null),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Hurt me anymore'), findsOneWidget);
    expect(find.text('0:45 écoutées'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });
}

Widget _app(ListeningActivityApi api) => ProviderScope(
  overrides: [listeningActivityApiProvider.overrideWithValue(api)],
  child: const MaterialApp(home: ListeningActivityScreen()),
);

class _FakeActivityApi extends ListeningActivityApi {
  _FakeActivityApi(this._load) : super(Dio());
  final Future<ListeningActivityPage> Function() _load;

  @override
  Future<ListeningActivityPage> fetchActivity({String? cursor}) => _load();
}
