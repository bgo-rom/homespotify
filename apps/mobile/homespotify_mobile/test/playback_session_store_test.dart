import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:homespotify_mobile/src/features/player/data/playback_session_store.dart';

void main() {
  test('la session sérialisée ne contient jamais de header ou de Bearer', () {
    final session = PersistedPlaybackSession(
      userId: 9,
      queue: [
        PersistedQueueItem(
          id: '42',
          userId: 9,
          streamUri: Uri.parse('https://music.example/api/tracks/42/stream'),
          title: 'Titre',
          artist: 'Artiste',
        ),
      ],
      currentIndex: 0,
      positionMs: 12345,
      repeatMode: 'one',
      shuffleEnabled: true,
      speedRatio: 1.08,
      wasPlaying: true,
      updatedAt: DateTime.utc(2026, 7, 21),
    );

    final encoded = jsonEncode(session.toJson());
    expect(encoded, isNot(contains('Authorization')));
    expect(encoded, isNot(contains('Bearer')));
    final decoded = PersistedPlaybackSession.fromJson(jsonDecode(encoded));
    expect(decoded?.userId, 9);
    expect(decoded?.positionMs, 12345);
    expect(decoded?.speedRatio, 1.08);
  });

  test('une URL non HTTP ou un mélange de comptes est refusé', () {
    final invalidUri = {
      'id': '1',
      'streamUri': 'file:///secret.flac',
      'title': 'Secret',
    };
    expect(PersistedQueueItem.fromJson(invalidUri), isNull);

    final mixedAccount = {
      'schemaVersion': playbackSessionSchemaVersion,
      'userId': 2,
      'queue': [
        {
          'id': '1',
          'userId': 3,
          'streamUri': 'https://music.example/api/tracks/1/stream',
          'title': 'Titre',
        },
      ],
      'currentIndex': 0,
      'positionMs': 0,
      'repeatMode': 'none',
      'shuffleEnabled': false,
      'speedRatio': 1,
      'wasPlaying': false,
      'updatedAt': '2026-07-21T00:00:00.000Z',
    };
    expect(PersistedPlaybackSession.fromJson(mixedAccount), isNull);
  });
}
